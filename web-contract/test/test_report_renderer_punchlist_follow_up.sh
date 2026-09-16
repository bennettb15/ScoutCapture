#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image="${SCOUTCAPTURE_REPORT_WORKER_IMAGE:-scoutcapture-report-worker:no-active-skip}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/scoutcapture-punchlist-follow-up.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

cp "$repo_root/ScoutCapture/Assets.xcassets/ScoutLogoNavy.imageset/ScoutLogoNavy.png" "$tmp_dir/follow-up.png"

python3 - "$tmp_dir" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

root = Path(sys.argv[1])
img = root / "follow-up.png"
sha = hashlib.sha256(img.read_bytes()).hexdigest()
session_id = "f19a4ecd-79ae-45a6-8618-e5c18363eaae"
snapshot_id = "23dce525-ec54-4e98-b857-ac25450de41a"
shot_id = "8cb52579-6752-409c-9ded-c76e8f6c11c1"

validation = {
    "schema_version": "phase1-report-input-1",
    "renderable_remotely": True,
    "source_snapshot_id": snapshot_id,
    "session_type": "punchlist_visit",
    "sessionType": "punchlist_visit",
    "gaps": [],
    "media": {"missing_count": 0},
    "inputs": {
        "session": {
            "session_id": session_id,
            "source_snapshot_id": snapshot_id,
            "session_type": "punchlist_visit",
            "sessionType": "punchlist_visit",
            "property_name": "QA Test 9.18",
            "property_address": "918 Slocum Ave",
            "property_city": "Raleigh",
            "property_state": "NC",
            "property_zip": "27601",
            "org_name": "Test Org",
            "started_at_utc": "2026-09-16T01:49:37Z",
            "completed_at_utc": "2026-09-16T01:49:48Z",
        },
        "ordered_shots": [
            {
                "session_id": session_id,
                "shot_id": shot_id,
                "building": "Building 1",
                "elevation": "North",
                "detail_type": "Punchlist Capture",
                "capture_kind": "follow_up_capture",
                "shot_type": "follow_up_capture",
                "angle_index": 1,
                "shot_key": "A1",
                "captured_at_utc": "2026-09-16T01:49:43Z",
                "original_filename": "follow-up.jpg",
                "is_flagged": False,
                "issue_id": None,
                "priority": None,
            }
        ],
        "property_report_entries": [],
    },
    "comparisons": {"items": []},
}
prepared = {
    "schema_version": "phase2a-prepared-media-1",
    "warnings": [],
    "items": [
        {
            "role": "current",
            "session_id": session_id,
            "shot_id": shot_id,
            "prepared_media_filename": img.name,
            "temporary_prepared_path": str(img),
            "deterministic_content_hash": sha,
            "warnings": [],
        }
    ],
}

(root / "validation.json").write_text(json.dumps(validation, indent=2), encoding="utf-8")
(root / "prepared.json").write_text(json.dumps(prepared, indent=2), encoding="utf-8")
PY

docker run --rm \
  --entrypoint python \
  -v "$tmp_dir:/fixture" \
  "$image" \
  /app/web-contract/report-renderer/report_renderer_phase2b.py \
    --validation-json /fixture/validation.json \
    --prepared-media-json /fixture/prepared.json \
    --output-dir /fixture/rendered \
    --report punchlist \
    --report-date 09/15/2026 \
    --logo-svg /app/web-contract/report-production/assets/ScoutOnlyLogo.svg \
    --pretty

python3 - "$tmp_dir/rendered/phase2c_summary.json" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1], encoding="utf-8"))
reports = summary.get("reports") or []
skipped = summary.get("skipped_reports") or []
assert [report.get("report_type") for report in reports] == ["punchlist_update"], reports
assert not reports[0].get("validation_failures"), reports[0]
assert reports[0].get("page_count", 0) >= 2, reports[0]
assert {item.get("report_type") for item in skipped} == {"priority", "comparison"}, skipped
assert any("no flagged shots" in item.get("reason", "") for item in skipped), skipped
assert any("no comparison entries" in item.get("reason", "") for item in skipped), skipped
print("punchlist follow-up renderer fallback test passed")
PY
