#!/usr/bin/env python3
"""One-time Storage-first cleanup for the exact deleted Test Org inventory."""
import argparse
import datetime as dt
import json
from pathlib import Path
import re
from urllib.error import HTTPError

from purge_expired_properties import Client, listed_storage_files, media_manifest

MANIFEST = Path(__file__).resolve().parents[1] / "supabase/ops/test_org_approved_purge.json"
RPC = "/rest/v1/rpc/finalize_approved_test_org_property_purge"


class ActiveOccupancyBlocked(RuntimeError):
    """The database forbids deleting a property with an active lock."""


def utc_timestamp(value):
    match = re.fullmatch(r"(\d{4}-\d\d-\d\d)[ T](\d\d:\d\d:\d\d(?:\.\d{1,6})?)(?:Z|\+00(?::00)?)", value)
    if not match:
        raise RuntimeError("Unexpected deletion timestamp format")
    value = match.group(1) + " " + match.group(2)
    format_string = "%Y-%m-%d %H:%M:%S.%f" if "." in value else "%Y-%m-%d %H:%M:%S"
    return dt.datetime.strptime(value, format_string).replace(tzinfo=dt.timezone.utc)


def verify_keep_set(client, manifest):
    for property_id in manifest["keep_property_ids"]:
        rows = client.rows("properties", select="id,org_id,is_archived,deleted_at", id=f"eq.{property_id}")
        if len(rows) != 1 or rows[0]["org_id"] != manifest["org_id"] or rows[0]["is_archived"] or rows[0]["deleted_at"] is not None:
            raise RuntimeError("A protected active Test Org property changed; cleanup stopped")


def verify_candidate(client, manifest, candidate):
    rows = client.rows("properties", select="id,org_id,is_archived,deleted_at",
                       id=f"eq.{candidate['id']}")
    if not rows:
        return None
    if len(rows) != 1 or rows[0]["org_id"] != manifest["org_id"] or rows[0]["is_archived"]:
        raise RuntimeError("Approved property changed organization or archive state")
    if rows[0]["deleted_at"] is None or utc_timestamp(rows[0]["deleted_at"]) != utc_timestamp(candidate["deleted_at"]):
        raise RuntimeError("Approved property deletion timestamp changed")
    return rows[0]


def rpc(client, property_id, dry_run):
    try:
        return client.request("POST", RPC, {"target_property_id": property_id, "dry_run": dry_run})
    except HTTPError as error:
        # The service response can include row values. Only expose its SQLSTATE and
        # constraint name to the workflow log; never log property IDs or record data.
        try:
            failure = json.loads(error.read())
        except (ValueError, UnicodeDecodeError):
            raise RuntimeError(f"Scoped purge HTTP {error.code}; database detail unavailable") from None
        code = failure.get("code", "unknown")
        message = failure.get("message", "")
        if code == "P0001" and message == "Property has active occupancy.":
            raise ActiveOccupancyBlocked("Property has active occupancy") from None
        constraint = re.search(r'constraint "([A-Za-z_][A-Za-z0-9_]*)"', message)
        label = constraint.group(1) if constraint else "unknown"
        raise RuntimeError(f"Scoped purge HTTP {error.code}; SQLSTATE {code}; constraint {label}") from None


def audit_remaining(client, manifest):
    verify_keep_set(client, manifest)
    totals = {
        "remaining": 0,
        "with_occupancy": 0,
        "with_locked_sessions": 0,
        "occupancy_updated_after_deletion": 0,
        "locks_updated_after_deletion": 0,
        "uploaded_shots_without_path": 0,
        "shot_paths_in_another_property_session": 0,
        "shot_paths_outside_property": 0,
    }
    for candidate in manifest["purge"]:
        current = verify_candidate(client, manifest, candidate)
        if current is None:
            continue
        totals["remaining"] += 1
        deleted_at = utc_timestamp(candidate["deleted_at"])
        occupancy = client.rows("property_session_occupancy",
            select="occupied_by_user_id,occupied_by_device_id,occupied_at,updated_at",
            property_id=f"eq.{candidate['id']}")
        active_occupancy = any(row.get("occupied_by_user_id") or
            (row.get("occupied_by_device_id") or "").strip() or row.get("occupied_at")
            for row in occupancy)
        if active_occupancy:
            totals["with_occupancy"] += 1
            if any(row.get("updated_at") and utc_timestamp(row["updated_at"]) > deleted_at
                   for row in occupancy):
                totals["occupancy_updated_after_deletion"] += 1
        sessions = client.rows("sessions",
            select="id,deleted_at,locked_by_user_id,locked_by_device_id,locked_at,updated_at",
            property_id=f"eq.{candidate['id']}")
        session_ids = {row["id"] for row in sessions}
        locked = [row for row in sessions if row.get("deleted_at") is None and
            (row.get("locked_by_user_id") or
             (row.get("locked_by_device_id") or "").strip() or row.get("locked_at"))]
        if locked:
            totals["with_locked_sessions"] += 1
            if any(row.get("updated_at") and utc_timestamp(row["updated_at"]) > deleted_at
                   for row in locked):
                totals["locks_updated_after_deletion"] += 1
        shots = client.rows("shots",
            select="session_id,storage_bucket,storage_path,upload_state",
            property_id=f"eq.{candidate['id']}")
        for shot in shots:
            path = shot.get("storage_path")
            if not path:
                if shot.get("upload_state") == "uploaded":
                    totals["uploaded_shots_without_path"] += 1
                continue
            if shot.get("storage_bucket") not in (None, "scoutcapture-originals") or not any(
                    path.startswith(f"sessions/{sid}/") for sid in session_ids):
                totals["shot_paths_outside_property"] += 1
            elif not path.startswith(f"sessions/{shot['session_id']}/"):
                totals["shot_paths_in_another_property_session"] += 1
    verify_keep_set(client, manifest)
    print(json.dumps({**totals, "mode": "audit"}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--audit-only", action="store_true")
    parser.add_argument("--limit", type=int, default=5)
    args = parser.parse_args()
    if args.execute and args.audit_only:
        raise SystemExit("--execute and --audit-only cannot be combined")
    if args.limit < 1 or args.limit > 20:
        raise SystemExit("--limit must be between 1 and 20")
    manifest = json.loads(MANIFEST.read_text())
    if manifest["org_id"] != "d4ba94ff-25e1-4072-aa79-9a548fcb3008" or len(manifest["purge"]) != 53 or len(manifest["keep_property_ids"]) != 5:
        raise RuntimeError("The reviewed Test Org allowlist changed")
    ids = [item["id"] for item in manifest["purge"]]
    if len(set(ids + manifest["keep_property_ids"])) != 58:
        raise RuntimeError("Approved and protected IDs overlap")

    client = Client()
    if args.audit_only:
        audit_remaining(client, manifest)
        return
    verify_keep_set(client, manifest)
    remaining = 0
    processed = 0
    media_total = 0
    blocked_active_occupancy = 0
    for candidate in manifest["purge"]:
        current = verify_candidate(client, manifest, candidate)
        if current is None:
            continue
        remaining += 1
        if processed >= args.limit:
            continue
        try:
            preflight = rpc(client, candidate["id"], True)
        except ActiveOccupancyBlocked:
            blocked_active_occupancy += 1
            continue
        if preflight is not False:
            raise RuntimeError("Scoped database function preflight failed")
        files = media_manifest(client, current, allow_legacy_pathless_shots=True,
                               allow_legacy_session_paths=True)
        media_total += sum(map(len, files.values()))
        if args.execute:
            verify_keep_set(client, manifest)
            for bucket, paths in files.items():
                client.remove_files(bucket, paths)
            session_ids = {row["id"] for row in client.rows(
                "sessions", select="id", property_id=f"eq.{candidate['id']}")}
            if any(listed_storage_files(client, manifest["org_id"],
                                        candidate["id"], session_ids).values()):
                raise RuntimeError("Storage still contains files; database rows retained")
            if rpc(client, candidate["id"], False) is not True:
                raise RuntimeError("Scoped database purge did not return true")
        processed += 1
    verify_keep_set(client, manifest)
    print(json.dumps({"remaining_at_start": remaining, "processed": processed,
                      "blocked_active_occupancy": blocked_active_occupancy,
                      "media_total": media_total,
                      "mode": "execute" if args.execute else "dry_run"}))


if __name__ == "__main__":
    main()
