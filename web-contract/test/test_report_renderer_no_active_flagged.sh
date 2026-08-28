#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image="${SCOUTCAPTURE_REPORT_WORKER_IMAGE:-scoutcapture-report-worker:no-active-skip}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/scoutcapture-no-active-flagged.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

cp "$repo_root/ScoutCapture/Assets.xcassets/ScoutLogoNavy.imageset/ScoutLogoNavy.png" "$tmp_dir/resolved-current.png"

python3 - "$tmp_dir" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

root = Path(sys.argv[1])
img = root / "resolved-current.png"
sha = hashlib.sha256(img.read_bytes()).hexdigest()
session_id = "11111111-1111-1111-1111-111111111111"
snapshot_id = "22222222-2222-2222-2222-222222222222"
shot_id = "33333333-3333-3333-3333-333333333333"

validation = {
    "schema_version": "phase1-report-input-1",
    "renderable_remotely": True,
    "source_snapshot_id": snapshot_id,
    "gaps": [],
    "media": {"missing_count": 0},
    "inputs": {
        "session": {
            "session_id": session_id,
            "source_snapshot_id": snapshot_id,
            "property_name": "QA Test 9.5",
            "property_address": "123 Test Way",
            "property_city": "Raleigh",
            "property_state": "NC",
            "property_zip": "27601",
            "org_name": "Test Org",
            "started_at_utc": "2026-08-28T12:00:00Z",
            "completed_at_utc": "2026-08-28T12:30:00Z",
        },
        "ordered_shots": [
            {
                "session_id": session_id,
                "shot_id": shot_id,
                "building": "Building 1",
                "elevation": "North",
                "detail_type": "Door",
                "angle_index": 1,
                "shot_key": "A1",
                "captured_at_utc": "2026-08-28T12:10:00Z",
                "original_filename": "resolved-current.heic",
                "is_flagged": False,
                "is_resolved_in_session": True,
                "issue_status": "resolved",
                "flagged_reason": "Resolved test item",
                "normalized_priority": "high",
            }
        ],
        "property_report_entries": [
            {
                "kind": "photo",
                "shot_id": shot_id,
                "building": "Building 1",
                "elevation": "North",
                "detail_type": "Door",
                "angle_index": 1,
                "shot_key": "A1",
            }
        ],
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
    --report all \
    --report-date 08/28/2026 \
    --logo-svg /app/web-contract/report-production/assets/ScoutOnlyLogo.svg \
    --pretty

python3 - "$tmp_dir/rendered/phase2c_summary.json" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1], encoding="utf-8"))
reports = summary.get("reports") or []
skipped = summary.get("skipped_reports") or []
assert [report.get("report_type") for report in reports] == ["property"], reports
assert not reports[0].get("validation_failures"), reports[0]
assert {item.get("report_type") for item in skipped} == {"priority", "comparison"}, skipped
assert any("no flagged shots" in item.get("reason", "") for item in skipped), skipped
print("no-active-flagged renderer skip test passed")
PY
