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
        constraint = re.search(r'constraint "([A-Za-z_][A-Za-z0-9_]*)"', message)
        label = constraint.group(1) if constraint else "unknown"
        raise RuntimeError(f"Scoped purge HTTP {error.code}; SQLSTATE {code}; constraint {label}") from None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--limit", type=int, default=5)
    args = parser.parse_args()
    if args.limit < 1 or args.limit > 20:
        raise SystemExit("--limit must be between 1 and 20")
    manifest = json.loads(MANIFEST.read_text())
    if manifest["org_id"] != "d4ba94ff-25e1-4072-aa79-9a548fcb3008" or len(manifest["purge"]) != 53 or len(manifest["keep_property_ids"]) != 5:
        raise RuntimeError("The reviewed Test Org allowlist changed")
    ids = [item["id"] for item in manifest["purge"]]
    if len(set(ids + manifest["keep_property_ids"])) != 58:
        raise RuntimeError("Approved and protected IDs overlap")

    client = Client()
    verify_keep_set(client, manifest)
    remaining = 0
    processed = 0
    media_total = 0
    for candidate in manifest["purge"]:
        current = verify_candidate(client, manifest, candidate)
        if current is None:
            continue
        remaining += 1
        if processed >= args.limit:
            continue
        if rpc(client, candidate["id"], True) is not False:
            raise RuntimeError("Scoped database function preflight failed")
        files = media_manifest(client, current)
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
                      "media_total": media_total,
                      "mode": "execute" if args.execute else "dry_run"}))


if __name__ == "__main__":
    main()
