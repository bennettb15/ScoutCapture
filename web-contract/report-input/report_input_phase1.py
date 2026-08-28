#!/usr/bin/env python3
"""ScoutCapture Phase 1 remote report-input assembler.

This is a read-only validator. It proves whether the current ScoutProcess report
inputs can be reconstructed from Supabase session snapshots, rawSessionJSON, and
remote storage metadata. It does not generate PDFs.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


ORIGINALS_BUCKET = "scoutcapture-originals"
SNAPSHOT_BUCKET = "scoutcapture-session-snapshots"
REPORT_GENERATOR_SOURCE = "ScoutProcess/ScoutProcess/PDFSessionReportGenerator.swift"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session-id", help="Completed ScoutCapture session UUID to validate.")
    parser.add_argument("--snapshot-id", help="Specific session_snapshots.id to validate.")
    parser.add_argument("--snapshot-row-fixture", help="Local JSON fixture for one session_snapshots row.")
    parser.add_argument("--snapshot-payload-fixture", help="Local JSON fixture for snapshot payload object.")
    parser.add_argument("--storage-fixture", help="Local JSON fixture describing existing storage objects.")
    parser.add_argument("--canonical-fixture", help="Local JSON fixture for remote historical sessions/shots.")
    parser.add_argument("--output", help="Write validation JSON to this path.")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print deterministic JSON.")
    parser.add_argument(
        "--include-runtime",
        action="store_true",
        help="Include volatile runtime metadata under runtime.",
    )
    return parser.parse_args()


class Phase1Error(RuntimeError):
    pass


class SupabaseReadClient:
    def __init__(self, url: str, key: str) -> None:
        self.url = url.rstrip("/")
        self.key = key

    @classmethod
    def from_env(cls) -> "SupabaseReadClient":
        url = os.environ.get("SUPABASE_URL", "").strip()
        key = (
            os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()
            or os.environ.get("SUPABASE_ANON_KEY", "").strip()
            or os.environ.get("SUPABASE_ACCESS_TOKEN", "").strip()
        )
        if not url or not key:
            raise Phase1Error(
                "SUPABASE_URL and a read-capable key are required unless fixtures are supplied."
            )
        return cls(url, key)

    def _request(self, method: str, url: str, accept: str = "application/json") -> bytes:
        req = urllib.request.Request(url, method=method)
        req.add_header("apikey", self.key)
        req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("Accept", accept)
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise Phase1Error(f"Supabase read failed {method} {url}: {error.code} {detail}") from error

    def select_rows(self, table: str, query: dict[str, str]) -> list[dict[str, Any]]:
        encoded = urllib.parse.urlencode(query, safe="(),.*")
        url = f"{self.url}/rest/v1/{table}?{encoded}"
        data = self._request("GET", url)
        value = json.loads(data.decode("utf-8"))
        if not isinstance(value, list):
            raise Phase1Error(f"Expected list response from {table}.")
        return value

    def download_storage_json(self, bucket: str, path: str) -> dict[str, Any]:
        encoded_path = "/".join(urllib.parse.quote(part) for part in path.split("/"))
        url = f"{self.url}/storage/v1/object/{urllib.parse.quote(bucket)}/{encoded_path}"
        data = self._request("GET", url)
        return json.loads(data.decode("utf-8"))

    def object_exists(self, bucket: str, path: str) -> bool:
        encoded_path = "/".join(urllib.parse.quote(part) for part in path.split("/"))
        url = f"{self.url}/storage/v1/object/{urllib.parse.quote(bucket)}/{encoded_path}"
        try:
            self._request("HEAD", url, accept="*/*")
            return True
        except Phase1Error:
            return False


class StorageProbe:
    def __init__(self, client: SupabaseReadClient | None, fixture: dict[str, Any] | None) -> None:
        self.client = client
        self.fixture_objects = normalize_storage_fixture(fixture)

    def exists(self, bucket: str | None, path: str | None) -> bool:
        if not bucket or not path:
            return False
        if self.fixture_objects is not None:
            return (bucket, path) in self.fixture_objects
        if self.client is None:
            return False
        return self.client.object_exists(bucket, path)


@dataclass(frozen=True)
class MaterialField:
    value: Any
    source: str


def read_json_file(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def normalize_storage_fixture(fixture: dict[str, Any] | None) -> set[tuple[str, str]] | None:
    if fixture is None:
        return None
    objects = fixture.get("objects", fixture if isinstance(fixture, list) else [])
    normalized: set[tuple[str, str]] = set()
    for item in objects:
        if isinstance(item, str):
            bucket, _, path = item.partition("/")
        else:
            bucket = item.get("bucket") or item.get("bucket_id")
            path = item.get("path") or item.get("name")
        if bucket and path:
            normalized.add((str(bucket), str(path)))
    return normalized


def stable_json(data: Any, pretty: bool) -> str:
    if pretty:
        return json.dumps(data, sort_keys=True, indent=2, separators=(",", ": ")) + "\n"
    return json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n"


def trim(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def bool_value(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "y"}


def parse_date(value: Any) -> dt.datetime | None:
    text = trim(value)
    if text is None:
        return None
    normalized = text.replace("Z", "+00:00")
    try:
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def iso(value: Any) -> str | None:
    parsed = parse_date(value)
    if parsed is None:
        return trim(value)
    return parsed.isoformat().replace("+00:00", "Z")


def sort_date_key(value: Any) -> str:
    return iso(value) or ""


def safe_int(value: Any, default: int = 0) -> int:
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def case_key(value: Any) -> str:
    return trim(value).upper() if trim(value) is not None else ""


def filename_leaf(value: str | None) -> str:
    text = trim(value) or ""
    return text.replace("\\", "/").split("/")[-1]


def sanitized_storage_filename(original_filename: str | None, shot_id: str) -> str:
    candidate = filename_leaf(original_filename)
    fallback = f"{shot_id.lower()}.jpg"
    base = candidate if candidate.strip() else fallback
    sanitized = "".join(ch if re.match(r"[A-Za-z0-9._-]", ch) else "_" for ch in base)
    return sanitized or fallback


def operational_media_storage_path(session_id: str, shot_id: str, original_filename: str | None) -> str:
    return (
        f"sessions/{session_id.lower()}/shots/{shot_id.lower()}/"
        f"{sanitized_storage_filename(original_filename, shot_id)}"
    )


def exported_shots(metadata: dict[str, Any]) -> list[dict[str, Any]]:
    shots = metadata.get("shots") or []
    result = []
    for shot in shots:
        lifecycle = trim(shot.get("lifecycleState")) or "active"
        if lifecycle == "active":
            result.append(shot)
    return result


def report_guided_rows(metadata: dict[str, Any]) -> list[dict[str, Any]]:
    return list(metadata.get("guidedShots") or [])


def issue_by_id(metadata: dict[str, Any]) -> dict[str, dict[str, Any]]:
    issues = metadata.get("issues") or []
    return {str(item.get("issueID") or item.get("issueId") or item.get("id")): item for item in issues}


def shot_id(shot: dict[str, Any]) -> str:
    return str(shot.get("shotID") or shot.get("id") or "")


def issue_id(shot: dict[str, Any]) -> str | None:
    return trim(shot.get("issueID") or shot.get("issueId"))


def shot_key(shot: dict[str, Any]) -> str:
    return trim(shot.get("shotKey")) or make_shot_key(
        shot.get("building"),
        shot.get("elevation"),
        shot.get("detailType"),
        safe_int(shot.get("angleIndex"), 1),
    )


def make_shot_key(building: Any, elevation: Any, detail_type: Any, angle_index: int) -> str:
    return "|".join(
        [
            normalize_key_part(building),
            normalize_key_part(elevation),
            normalize_key_part(detail_type),
            str(max(1, angle_index)),
        ]
    )


def normalize_key_part(value: Any) -> str:
    text = trim(value) or ""
    text = re.sub(r"[^A-Za-z0-9]+", "_", text.lower()).strip("_")
    return text


def logical_shot_identity(metadata: dict[str, Any], shot: dict[str, Any]) -> str:
    explicit = trim(shot.get("logicalShotIdentity"))
    if explicit:
        return explicit
    normalized_key = shot_key(shot).strip().lower()
    flagged_lane = bool_value(shot.get("isFlagged")) or issue_id(shot) is not None or trim(
        shot.get("issueStatus") or shot.get("captureKind")
    ) is not None
    lane = f"flagged|{issue_id(shot).lower() if issue_id(shot) else 'no-issue'}" if flagged_lane else "normal"
    return f"{str(metadata.get('sessionID')).lower()}|{lane}|{normalized_key}"


def is_resolved_in_session(metadata: dict[str, Any], shot: dict[str, Any], issues: dict[str, dict[str, Any]]) -> bool:
    sid = str(metadata.get("sessionID") or "")
    iid = issue_id(shot)
    issue = issues.get(iid or "")
    if issue:
        status = (trim(issue.get("issueStatus") or issue.get("status")) or "").lower()
        resolved_at = trim(issue.get("resolvedAt") or issue.get("resolved_at"))
        last_capture = trim(issue.get("lastCaptureSessionId") or issue.get("last_capture_session_id")) or sid
        return (bool(resolved_at) or status == "resolved") and last_capture.lower() == sid.lower()
    status = (trim(shot.get("issueStatus")) or "").lower()
    return status == "resolved"


def flagged_reason(shot: dict[str, Any], issues: dict[str, dict[str, Any]]) -> str | None:
    direct = trim(shot.get("flaggedReason") or shot.get("reason") or shot.get("noteText"))
    if direct:
        return direct
    iid = issue_id(shot)
    issue = issues.get(iid or "")
    if not issue:
        return None
    return trim(issue.get("currentReason") or issue.get("reason") or issue.get("detailNote"))


def previous_reason(previous: dict[str, Any]) -> str | None:
    return trim(
        previous.get("flaggedReason")
        or previous.get("reason")
        or previous.get("noteText")
        or previous.get("previousReason")
        or previous.get("currentReason")
    )


def report_shot(metadata: dict[str, Any], shot: dict[str, Any], issues: dict[str, dict[str, Any]]) -> dict[str, Any]:
    sid = str(metadata.get("sessionID") or "")
    sid_shot = shot_id(shot)
    original = trim(shot.get("originalFilename")) or ""
    bucket = trim(shot.get("storageBucket")) or ORIGINALS_BUCKET
    path = trim(shot.get("storagePath")) or operational_media_storage_path(sid, sid_shot, original)
    captured = iso(shot.get("createdAt") or shot.get("capturedAt") or shot.get("captured_at"))
    return {
        "shot_id": sid_shot,
        "session_id": sid,
        "building": trim(shot.get("building")),
        "elevation": trim(shot.get("elevation")),
        "detail_type": trim(shot.get("detailType")),
        "angle_index": max(1, safe_int(shot.get("angleIndex"), 1)),
        "shot_key": shot_key(shot),
        "logical_shot_identity": logical_shot_identity(metadata, shot),
        "captured_at_utc": captured,
        "latitude": shot.get("latitude"),
        "longitude": shot.get("longitude"),
        "original_filename": original,
        "stamped_jpeg_filename": trim(shot.get("stampedFilename")),
        "is_flagged": bool_value(shot.get("isFlagged")),
        "is_resolved_in_session": is_resolved_in_session(metadata, shot, issues),
        "flagged_reason": flagged_reason(shot, issues),
        "priority": trim(shot.get("priority")),
        "normalized_priority": normalized_priority(trim(shot.get("priority"))),
        "media": {
            "bucket": bucket,
            "path": path,
            "path_source": "session_snapshots.rawSessionJSON" if trim(shot.get("storagePath")) else "derived_report_rule",
            "checksum_sha256": trim(shot.get("checksumSHA256") or shot.get("checksum_sha256")),
            "byte_size": shot.get("byteSize") or shot.get("byte_size") or shot.get("originalByteSize"),
            "upload_state": trim(shot.get("uploadState")) or ("uploaded" if trim(shot.get("storagePath")) else None),
        },
    }


def normalized_priority(value: str | None) -> str:
    lowered = (value or "").strip().lower()
    if lowered in {"critical", "high", "medium", "low"}:
        return lowered
    return "medium"


def section_grouping_key(building: Any, elevation: Any) -> str:
    building_label = friendly_building_label(display_text(building, "Building")).upper()
    elevation_label = display_text(elevation, "Unknown").upper()
    return f"{building_label}|{elevation_label}"


def slot_key(building: Any, elevation: Any, detail_type: Any, shot_key_value: Any, angle_index: Any) -> str:
    return "|".join(
        [
            display_text(building, "B1").upper(),
            display_text(elevation, "North").upper(),
            display_text(detail_type, "General Elevation").upper(),
            detail_identifier(shot_key_value, angle_index),
        ]
    )


def detail_identifier(shot_key_value: Any, angle_index: Any) -> str:
    key = trim(shot_key_value)
    if key and re.match(r"^A\d+$", key.upper()):
        return key.upper()
    return f"A{safe_int(angle_index, 0)}"


def display_text(value: Any, fallback: str) -> str:
    return trim(value) or fallback


def numeric_suffix(prefix: str, value: Any) -> str | None:
    text = trim(value) or ""
    match = re.match(rf"^{re.escape(prefix)}\s*(\d+)$", text, flags=re.IGNORECASE)
    return match.group(1) if match else None


def friendly_building_label(value: str) -> str:
    suffix = numeric_suffix("B", value)
    if suffix is not None:
        return f"Building {suffix}"
    return value


def detail_sort_priority(detail_type: Any) -> int:
    detail = display_text(detail_type, "General Elevation").upper()
    if detail == "OVERVIEW":
        return 0
    if detail == "ELEVATION":
        return 1
    return 2


def ordered_section_keys(metadata: dict[str, Any], report_shots: list[dict[str, Any]]) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()
    for shot in report_shots:
        key = section_grouping_key(shot.get("building"), shot.get("elevation"))
        if key not in seen:
            seen.add(key)
            ordered.append(key)
    for row in report_guided_rows(metadata):
        key = section_grouping_key(row.get("building"), row.get("targetElevation") or row.get("elevation"))
        if key not in seen:
            seen.add(key)
            ordered.append(key)
    return ordered


def section_order_index(entry: dict[str, Any], ordered_sections: list[str]) -> int:
    key = section_grouping_key(entry.get("building"), entry.get("elevation"))
    try:
        return ordered_sections.index(key)
    except ValueError:
        return sys.maxsize


def was_retired_during_session(row: dict[str, Any], started: Any, ended: Any) -> bool:
    if not bool_value(row.get("isRetired")) and (trim(row.get("status")) or "").lower() != "retired":
        return False
    retired = parse_date(row.get("retiredAt") or row.get("retired_at"))
    start = parse_date(started)
    if retired is None or start is None:
        return False
    end = parse_date(ended) or (start + dt.timedelta(days=1))
    return start <= retired <= end


def guided_placeholders(metadata: dict[str, Any], report_shots: list[dict[str, Any]]) -> dict[str, Any]:
    rows = report_guided_rows(metadata)
    started = metadata.get("startedAt")
    ended = metadata.get("endedAt")
    session_id = str(metadata.get("sessionID") or "")
    retired_slot_keys: set[str] = set()
    skipped_by_slot: dict[str, dict[str, Any]] = {}
    retired_notes: list[dict[str, Any]] = []

    for row in rows:
        key = slot_key(row.get("building"), row.get("targetElevation"), row.get("detailType"), None, row.get("angleIndex"))
        if was_retired_during_session(row, started, ended):
            retired_slot_keys.add(key)
            retired_notes.append(
                {
                    "guided_row_id": str(row.get("id") or ""),
                    "slot_key": key,
                    "section_key": section_grouping_key(row.get("building"), row.get("targetElevation")),
                    "source": "session_snapshots.rawSessionJSON",
                }
            )
            continue
        skip_reason = trim(row.get("skipReason") or row.get("skipReasonNote"))
        skip_session = trim(row.get("skipSessionID")) or session_id
        if skip_reason and skip_session.lower() == session_id.lower():
            skipped_by_slot[key] = row

    slots_with_shots = {
        slot_key(shot.get("building"), shot.get("elevation"), shot.get("detail_type"), shot.get("shot_key"), shot.get("angle_index"))
        for shot in report_shots
    }
    placeholders = []
    for row in rows:
        key = slot_key(row.get("building"), row.get("targetElevation"), row.get("detailType"), None, row.get("angleIndex"))
        if key in retired_slot_keys or key in slots_with_shots:
            continue
        skipped = skipped_by_slot.get(key)
        if skipped:
            placeholders.append(
                {
                    "guided_row_id": str(skipped.get("id") or ""),
                    "slot_key": key,
                    "building": trim(skipped.get("building")),
                    "elevation": trim(skipped.get("targetElevation")),
                    "detail_type": trim(skipped.get("detailType")),
                    "angle_index": safe_int(skipped.get("angleIndex"), 0),
                    "skip_reason": trim(skipped.get("skipReason") or skipped.get("skipReasonNote")),
                    "source": "session_snapshots.rawSessionJSON",
                }
            )
    return {
        "source": "session_snapshots.rawSessionJSON",
        "guided_rows_considered": len(rows),
        "skipped_placeholders": placeholders,
        "skipped_placeholder_count": len(placeholders),
        "retired_notes": retired_notes,
        "retired_note_count": len(retired_notes),
    }


def property_report_entries(metadata: dict[str, Any], report_shots: list[dict[str, Any]]) -> list[dict[str, Any]]:
    placeholders = guided_placeholders(metadata, report_shots)
    entries = []
    for shot in report_shots:
        entries.append(
            {
                "kind": "photo",
                "shot_id": shot["shot_id"],
                "building": shot.get("building"),
                "elevation": shot.get("elevation"),
                "detail_type": shot.get("detail_type"),
                "angle_index": shot.get("angle_index"),
                "is_skipped": False,
                "slot_key": slot_key(
                    shot.get("building"),
                    shot.get("elevation"),
                    shot.get("detail_type"),
                    shot.get("shot_key"),
                    shot.get("angle_index"),
                ),
                "captured_at_utc": shot.get("captured_at_utc"),
                "original_filename": shot.get("original_filename"),
            }
        )
    for placeholder in placeholders["skipped_placeholders"]:
        entries.append(
            {
                "kind": "skipped_guided_row",
                "guided_row_id": placeholder["guided_row_id"],
                "building": placeholder.get("building"),
                "elevation": placeholder.get("elevation"),
                "detail_type": placeholder.get("detail_type"),
                "angle_index": placeholder.get("angle_index"),
                "is_skipped": True,
                "slot_key": placeholder["slot_key"],
                "captured_at_utc": None,
                "original_filename": "",
            }
        )
    ordered_sections = ordered_section_keys(metadata, report_shots)
    entries.sort(
        key=lambda item: (
            section_order_index(item, ordered_sections),
            detail_sort_priority(item.get("detail_type")),
            display_text(item.get("detail_type"), "General Elevation").upper(),
            safe_int(item.get("angle_index"), 0),
            item.get("is_skipped") is True,
            sort_date_key(item.get("captured_at_utc")),
            (item.get("original_filename") or "").lower(),
        )
    )
    for item in entries:
        item.pop("is_skipped", None)
    return entries


def load_snapshot_row(args: argparse.Namespace, client: SupabaseReadClient | None) -> dict[str, Any]:
    if args.snapshot_row_fixture:
        row = read_json_file(args.snapshot_row_fixture)
        if isinstance(row, list):
            if not row:
                raise Phase1Error("Snapshot row fixture list is empty.")
            return row[0]
        return row
    if client is None:
        raise Phase1Error("A snapshot row fixture or Supabase credentials are required.")
    query = {
        "select": "*",
        "order": "created_at.desc",
        "limit": "1",
    }
    if args.snapshot_id:
        query["id"] = f"eq.{args.snapshot_id}"
    elif args.session_id:
        query["session_id"] = f"eq.{args.session_id}"
        query["snapshot_kind"] = "eq.completed"
        query["is_sealed"] = "eq.true"
        query["deleted_at"] = "is.null"
    else:
        raise Phase1Error("--session-id or --snapshot-id is required without fixtures.")
    rows = client.select_rows("session_snapshots", query)
    if not rows:
        raise Phase1Error("No matching completed/sealed session_snapshots row found.")
    return rows[0]


def load_snapshot_payload(args: argparse.Namespace, client: SupabaseReadClient | None, row: dict[str, Any]) -> dict[str, Any]:
    if args.snapshot_payload_fixture:
        return read_json_file(args.snapshot_payload_fixture)
    if client is None:
        raise Phase1Error("A snapshot payload fixture or Supabase credentials are required.")
    bucket = row.get("payload_storage_bucket")
    path = row.get("payload_storage_path")
    if not bucket or not path:
        raise Phase1Error("Snapshot row is missing payload_storage_bucket/path.")
    return client.download_storage_json(str(bucket), str(path))


def payload_raw_metadata(payload: dict[str, Any]) -> dict[str, Any]:
    raw = payload.get("rawSessionJSON")
    if not isinstance(raw, str):
        raise Phase1Error("Snapshot payload is missing rawSessionJSON.")
    try:
        metadata = json.loads(raw)
    except json.JSONDecodeError as error:
        raise Phase1Error("rawSessionJSON is not valid JSON.") from error
    if not isinstance(metadata, dict):
        raise Phase1Error("rawSessionJSON did not decode to an object.")
    return metadata


def media_validations(report_shots: list[dict[str, Any]], storage: StorageProbe) -> list[dict[str, Any]]:
    result = []
    for shot in report_shots:
        media = shot["media"]
        bucket = media.get("bucket")
        path = media.get("path")
        expected_path = operational_media_storage_path(shot["session_id"], shot["shot_id"], shot["original_filename"])
        exists = storage.exists(bucket, path)
        result.append(
            {
                "shot_id": shot["shot_id"],
                "bucket": bucket,
                "path": path,
                "expected_convention_path": expected_path,
                "matches_upload_convention": path == expected_path,
                "exists": exists,
                "upload_state": media.get("upload_state"),
                "source": media.get("path_source"),
            }
        )
    return sorted(result, key=lambda item: item["shot_id"])


def load_canonical_history(args: argparse.Namespace, client: SupabaseReadClient | None, metadata: dict[str, Any]) -> dict[str, Any]:
    if args.canonical_fixture:
        return read_json_file(args.canonical_fixture)
    if client is None:
        return {"sessions": [], "shots": [], "source": "unavailable"}
    property_id = str(metadata.get("propertyID") or "")
    started = iso(metadata.get("startedAt")) or ""
    if not property_id or not started:
        return {"sessions": [], "shots": [], "source": "unavailable"}
    sessions = client.select_rows(
        "sessions",
        {
            "select": "id,property_id,started_at,completed_at,status,deleted_at",
            "property_id": f"eq.{property_id}",
            "started_at": f"lt.{started}",
            "deleted_at": "is.null",
            "order": "started_at.desc",
            "limit": "100",
        },
    )
    session_ids = [item["id"] for item in sessions if item.get("id")]
    if not session_ids:
        return {"sessions": sessions, "shots": [], "source": "supabase_canonical"}
    in_list = ",".join(session_ids)
    shots = client.select_rows(
        "shots",
        {
            "select": "id,session_id,building,elevation,detail_type,angle_index,shot_key,captured_at,storage_bucket,storage_path,is_flagged,issue_id,issue_status,reason,priority,checksum_sha256,byte_size,upload_state,deleted_at",
            "session_id": f"in.({in_list})",
            "deleted_at": "is.null",
            "order": "captured_at.desc",
            "limit": "1000",
        },
    )
    return {"sessions": sessions, "shots": shots, "source": "supabase_canonical"}


def comparable_previous_shot(
    current_session_started: Any,
    current: dict[str, Any],
    history: dict[str, Any],
) -> tuple[dict[str, Any] | None, int]:
    sessions_by_id = {str(item.get("id")): item for item in history.get("sessions", [])}
    candidates = []
    for shot in history.get("shots", []):
        session = sessions_by_id.get(str(shot.get("session_id")))
        if not session:
            continue
        if parse_date(session.get("started_at")) is None or parse_date(current_session_started) is None:
            continue
        if parse_date(session.get("started_at")) >= parse_date(current_session_started):
            continue
        if case_key(shot.get("building")) != case_key(current.get("building")):
            continue
        if case_key(shot.get("elevation")) != case_key(current.get("elevation")):
            continue
        if case_key(shot.get("detail_type")) != case_key(current.get("detail_type")):
            continue
        if safe_int(shot.get("angle_index"), -1) != safe_int(current.get("angle_index"), -1):
            continue
        candidates.append((session, shot))
    candidates.sort(key=lambda pair: (sort_date_key(pair[0].get("started_at")), sort_date_key(pair[1].get("captured_at"))), reverse=True)
    if not candidates:
        return None, 0
    session, shot = candidates[0]
    bucket = trim(shot.get("storage_bucket"))
    path = trim(shot.get("storage_path"))
    return {
        "shot_id": str(shot.get("id") or ""),
        "session_id": str(shot.get("session_id") or ""),
        "session_started_at": iso(session.get("started_at")),
        "captured_at_utc": iso(shot.get("captured_at")),
        "building": trim(shot.get("building")),
        "elevation": trim(shot.get("elevation")),
        "detail_type": trim(shot.get("detail_type")),
        "angle_index": safe_int(shot.get("angle_index"), 0),
        "shot_key": trim(shot.get("shot_key")),
        "is_flagged": bool_value(shot.get("is_flagged")),
        "is_resolved_in_session": (trim(shot.get("issue_status")) or "").lower() == "resolved",
        "flagged_reason": previous_reason(shot),
        "media": {
            "bucket": bucket,
            "path": path,
            "source": "normalized_canonical_supabase_row",
        },
    }, len(candidates)


def comparison_sort_key(shot: dict[str, Any]) -> tuple[str, str, str, str, str, str]:
    return (
        friendly_building_label(display_text(shot.get("building"), "B1")).upper(),
        display_text(shot.get("elevation"), "Unknown").upper(),
        display_text(shot.get("detail_type"), "General Elevation").upper(),
        f"{safe_int(shot.get('angle_index'), 0):05d}",
        shot.get("captured_at_utc") or "",
        shot.get("original_filename") or "",
    )


def comparison_validations(
    metadata: dict[str, Any],
    comparison_shots: list[dict[str, Any]],
    history: dict[str, Any],
    storage: StorageProbe,
) -> list[dict[str, Any]]:
    results = []
    for current in comparison_shots:
        previous, candidate_count = comparable_previous_shot(metadata.get("startedAt"), current, history)
        previous_media_exists = False
        if previous:
            previous_media_exists = storage.exists(previous["media"].get("bucket"), previous["media"].get("path"))
        results.append(
            {
                "current_shot_id": current["shot_id"],
                "identity_fields": {
                    "property_id": str(metadata.get("propertyID") or ""),
                    "building": current.get("building"),
                    "elevation": current.get("elevation"),
                    "detail_type": current.get("detail_type"),
                    "angle_index": current.get("angle_index"),
                },
                "previous_shot_id": previous.get("shot_id") if previous else None,
                "previous_session_id": previous.get("session_id") if previous else None,
                "candidate_count": candidate_count,
                "selected_match": previous is not None,
                "previous_media_exists": previous_media_exists,
                "source": history.get("source", "unavailable"),
                "gap": None if previous or history.get("source") != "unavailable" else "remote_historical_data_unavailable",
            }
        )
    return results


def session_input(metadata: dict[str, Any], payload: dict[str, Any], row: dict[str, Any]) -> dict[str, Any]:
    return {
        "session_id": str(metadata.get("sessionID") or ""),
        "property_id": str(metadata.get("propertyID") or ""),
        "org_id": str(metadata.get("orgID") or payload.get("orgID") or row.get("org_id") or ""),
        "org_name": trim(metadata.get("orgNameAtCapture")),
        "folder_id": trim(metadata.get("folderIDAtCapture")),
        "property_name": trim(metadata.get("propertyNameAtExport") or metadata.get("propertyNameAtCapture")),
        "property_address": trim(metadata.get("propertyAddressAtCapture")),
        "property_street": trim(metadata.get("propertyStreetAtCapture")),
        "property_city": trim(metadata.get("propertyCityAtCapture")),
        "property_state": trim(metadata.get("propertyStateAtCapture")),
        "property_zip": trim(metadata.get("propertyZipAtCapture")),
        "started_at_utc": iso(metadata.get("startedAt")),
        "ended_at_utc": iso(metadata.get("endedAt")),
        "status": trim(metadata.get("status") or payload.get("status") or row.get("session_status")),
        "is_sealed": bool_value(metadata.get("isSealed") if "isSealed" in metadata else payload.get("isSealed")),
        "provenance": {
            "identity": ["session_snapshots.rawSessionJSON", "session_snapshot_metadata"],
            "property_display_fields": ["session_snapshots.rawSessionJSON"],
            "timestamps": ["session_snapshots.rawSessionJSON"],
        },
    }


def build_validation(args: argparse.Namespace) -> dict[str, Any]:
    client = None if args.snapshot_row_fixture and args.snapshot_payload_fixture else SupabaseReadClient.from_env()
    row = load_snapshot_row(args, client)
    payload = load_snapshot_payload(args, client, row)
    metadata = payload_raw_metadata(payload)
    storage_fixture = read_json_file(args.storage_fixture) if args.storage_fixture else None
    storage = StorageProbe(client, storage_fixture)
    issues = issue_by_id(metadata)
    shots = [report_shot(metadata, shot, issues) for shot in exported_shots(metadata)]
    shots.sort(key=lambda item: (item.get("captured_at_utc") or "", item.get("original_filename") or ""))

    media = media_validations(shots, storage)
    missing_media = [item for item in media if not item["exists"]]
    current_comparison_shots = [
        shot for shot in shots if shot["is_flagged"] or shot["is_resolved_in_session"]
    ]
    current_comparison_shots.sort(key=comparison_sort_key)
    priority_shots = [
        shot for shot in shots if shot["is_flagged"] and not shot["is_resolved_in_session"]
    ]
    priority_counts: dict[str, int] = {"critical": 0, "high": 0, "medium": 0, "low": 0}
    for shot in priority_shots:
        priority_counts[shot["normalized_priority"]] += 1

    history = load_canonical_history(args, client, metadata)
    comparisons = comparison_validations(metadata, current_comparison_shots, history, storage)
    guided = guided_placeholders(metadata, shots)
    entries = property_report_entries(metadata, shots)

    gaps = []
    warnings = []
    if missing_media:
        gaps.append(
            {
                "code": "missing_remote_original_media",
                "severity": "blocker",
                "count": len(missing_media),
                "detail": "At least one required source original is unavailable in Supabase Storage.",
            }
        )
    if history.get("source") == "unavailable" and current_comparison_shots:
        gaps.append(
            {
                "code": "remote_previous_comparison_source_unavailable",
                "severity": "blocker",
                "detail": "Flagged Comparison prior-shot matching cannot be proven without remote historical session/shot rows.",
            }
        )
    if any(item["previous_shot_id"] and not item["previous_media_exists"] for item in comparisons):
        gaps.append(
            {
                "code": "missing_remote_previous_comparison_media",
                "severity": "blocker",
                "detail": "A selected prior comparable shot is missing remote media.",
            }
        )
    if any(not item["matches_upload_convention"] for item in media):
        warnings.append(
            {
                "code": "storage_path_differs_from_current_upload_convention",
                "detail": "rawSessionJSON supplied storagePath differs from the current operationalMediaStoragePath convention.",
            }
        )
    if row.get("snapshot_kind") not in (None, "completed"):
        warnings.append({"code": "snapshot_kind_not_completed", "snapshot_kind": row.get("snapshot_kind")})
    if not bool_value(row.get("is_sealed", payload.get("isSealed", metadata.get("isSealed")))):
        warnings.append({"code": "snapshot_or_session_not_sealed"})

    renderable = not any(gap["severity"] == "blocker" for gap in gaps)
    output = {
        "schema_version": 1,
        "session_id": str(metadata.get("sessionID") or row.get("session_id") or ""),
        "source_snapshot_id": str(row.get("id") or payload.get("id") or ""),
        "renderable_remotely": renderable,
        "reports": {
            "property_report": {
                "generator_method": "generateSessionReport",
                "source_of_truth": REPORT_GENERATOR_SOURCE,
                "reconstructable": len(missing_media) == 0,
                "photo_entry_count": len([item for item in entries if item["kind"] == "photo"]),
                "skipped_placeholder_count": guided["skipped_placeholder_count"],
                "retired_note_count": guided["retired_note_count"],
                "entry_count": len(entries),
            },
            "flagged_comparison": {
                "generator_method": "generateFlaggedComparisonReport",
                "source_of_truth": REPORT_GENERATOR_SOURCE,
                "applicable": len(current_comparison_shots) > 0,
                "reconstructable": len(current_comparison_shots) == 0
                or (
                    history.get("source") != "unavailable"
                    and all((not item["previous_shot_id"]) or item["previous_media_exists"] for item in comparisons)
                    and len(missing_media) == 0
                ),
                "current_flagged_or_resolved_count": len(current_comparison_shots),
                "comparison_count": len(comparisons),
            },
            "priority_report": {
                "generator_method": "generatePriorityItemsReport",
                "source_of_truth": REPORT_GENERATOR_SOURCE,
                "applicable": len(priority_shots) > 0,
                "reconstructable": len(priority_shots) == 0 or len(missing_media) == 0,
                "flagged_shot_count": len(priority_shots),
                "priority_counts": priority_counts,
                "default_priority_rule": "missing_or_unrecognized_priority_defaults_to_medium",
            },
        },
        "inputs": {
            "session": session_input(metadata, payload, row),
            "ordered_shots": shots,
            "property_report_entries": entries,
        },
        "media": {
            "bucket_convention": ORIGINALS_BUCKET,
            "path_convention": "sessions/{session_id}/shots/{shot_id}/{sanitized original filename}",
            "required_count": len(media),
            "found_count": len([item for item in media if item["exists"]]),
            "missing_count": len(missing_media),
            "items": media,
        },
        "comparisons": {
            "matching_rule": {
                "property": "same property_id",
                "session": "sessions.started_at_utc < current_session.started_at_utc",
                "identity": "case-insensitive building, elevation, detail_type; angle_index equality",
                "order": "sessions.started_at_utc DESC, shots.captured_at_utc DESC, limit 1",
                "source_of_truth": "PDFSessionReportGenerator.fetchPreviousComparableShot",
            },
            "items": comparisons,
        },
        "guided_placeholders": guided,
        "data_sources": {
            "session_snapshot_row": "session_snapshots",
            "snapshot_payload": "Supabase Storage scoutcapture-session-snapshots or fixture",
            "raw_session_json": "session_snapshots payload rawSessionJSON",
            "original_media": "Supabase Storage scoutcapture-originals",
            "previous_comparison_history": history.get("source", "unavailable"),
        },
        "field_provenance": field_provenance(),
        "gaps": gaps,
        "warnings": warnings,
    }
    if args.include_runtime:
        output["runtime"] = {
            "generated_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "tool": "web-contract/report-input/report_input_phase1.py",
            "tool_sha256": tool_sha256(),
        }
    return output


def field_provenance() -> dict[str, Any]:
    return {
        "session_identity": ["session_snapshots.rawSessionJSON", "session_snapshot_metadata"],
        "org_property_identity": ["session_snapshots.rawSessionJSON", "session_snapshot_metadata"],
        "property_display_fields": ["session_snapshots.rawSessionJSON"],
        "session_timestamps": ["session_snapshots.rawSessionJSON"],
        "ordered_shots": ["session_snapshots.rawSessionJSON", "derived_report_rule: exported active shots ordered by captured_at_utc, original_filename"],
        "guided_rows": ["session_snapshots.rawSessionJSON", "PDF generator input: all session guided rows"],
        "guided_skipped_placeholders": ["session_snapshots.rawSessionJSON", "derived_report_rule: skipped current-session slot with no shot"],
        "guided_retired_notes": ["session_snapshots.rawSessionJSON", "derived_report_rule: retired during session"],
        "shot_identity_fields": ["session_snapshots.rawSessionJSON"],
        "logical_shot_identity": ["session_snapshots.rawSessionJSON", "derived_report_rule fallback"],
        "captured_at_utc": ["session_snapshots.rawSessionJSON"],
        "gps": ["session_snapshots.rawSessionJSON"],
        "original_filename": ["session_snapshots.rawSessionJSON"],
        "stamped_jpeg_filename": ["session_snapshots.rawSessionJSON if present", "derived_report_rule future"],
        "is_flagged": ["session_snapshots.rawSessionJSON"],
        "resolved_in_session": ["session_snapshots.rawSessionJSON issues", "derived_report_rule mirroring ScoutProcess SQL CASE"],
        "flagged_reason": ["session_snapshots.rawSessionJSON shot.noteText/reason", "session_snapshots.rawSessionJSON issue.currentReason"],
        "priority": ["session_snapshots.rawSessionJSON", "derived_report_rule default Medium"],
        "current_media_path": ["session_snapshots.rawSessionJSON storageBucket/storagePath", "derived_report_rule operationalMediaStoragePath fallback", "Supabase Storage object"],
        "previous_comparable_shot": ["normalized canonical Supabase sessions/shots", "derived_report_rule mirroring fetchPreviousComparableShot"],
        "previous_media_path": ["normalized canonical Supabase shots.storage_bucket/storage_path", "Supabase Storage object"],
    }


def tool_sha256() -> str:
    with open(__file__, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def main() -> int:
    args = parse_args()
    try:
        validation = build_validation(args)
        text = stable_json(validation, args.pretty)
        if args.output:
            with open(args.output, "w", encoding="utf-8") as handle:
                handle.write(text)
        else:
            sys.stdout.write(text)
        return 0
    except Phase1Error as error:
        sys.stderr.write(f"phase1 validation failed: {error}\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
