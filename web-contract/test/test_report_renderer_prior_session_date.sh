#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="/Users/brian/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/scoutcapture-prior-session-date.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

"$PY" - "$OUT" <<'PY'
from pathlib import Path
from PIL import Image
import hashlib
import json
import sys

root = Path(sys.argv[1])
image_path = root / "comparison.jpg"
Image.new("RGB", (1200, 800), (150, 170, 190)).save(image_path, "JPEG", quality=90)
image_hash = hashlib.sha256(image_path.read_bytes()).hexdigest()

def validation(path: Path, include_previous_dates: bool) -> None:
    comparison = {
        "current_shot_id": "current-shot",
        "previous_shot_id": "previous-shot",
        "previous_session_id": "previous-session",
        "previous_media_exists": True,
        "selected_match": True,
        "candidate_count": 1,
        "source": "fixture",
    }
    if include_previous_dates:
        comparison.update(
            {
                "previous_session_completed_at_utc": "2026-08-18T21:30:00Z",
                "previous_captured_at_utc": "2026-08-17T14:15:00Z",
            }
        )
    payload = {
        "session_id": "current-session",
        "source_snapshot_id": "snapshot",
        "inputs": {
            "session": {
                "session_id": "current-session",
                "property_name": "Prior Date Fixture",
                "property_street": "1 Fixture Way",
                "property_city": "Raleigh",
                "property_state": "NC",
                "property_zip": "27601",
                "started_at_utc": "2026-08-19T14:00:00Z",
                "ended_at_utc": "2026-08-19T15:00:00Z",
            },
            "ordered_shots": [
                {
                    "shot_id": "current-shot",
                    "session_id": "current-session",
                    "building": "B1",
                    "elevation": "North",
                    "detail_type": "Door",
                    "angle_index": 1,
                    "shot_key": "A1",
                    "captured_at_utc": "2026-08-19T14:10:00Z",
                    "is_flagged": True,
                    "is_resolved_in_session": False,
                    "flagged_reason": "Paint peeling",
                    "original_filename": "current.jpg",
                    "media": {"bucket": "fixture", "path": str(image_path)},
                }
            ],
            "property_report_entries": [{"kind": "photo", "shot_id": "current-shot"}],
        },
        "comparisons": {"items": [comparison]},
        "guided_placeholders": {"retired_notes": []},
    }
    path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")

prepared = {
    "warnings": [],
    "items": [
        {
            "role": role,
            "session_id": f"{role}-session",
            "shot_id": f"{role}-shot",
            "temporary_prepared_path": str(image_path),
            "prepared_width": 1200,
            "prepared_height": 800,
            "prepared_media_filename": image_path.name,
            "prepared_media_mime_type": "image/jpeg",
            "deterministic_content_hash": image_hash,
            "flag_resolved_state_applied": "flagged",
            "warnings": [],
        }
        for role in ("current", "previous")
    ],
}

validation(root / "with_previous_session_date.json", True)
validation(root / "without_previous_session_date.json", False)
(root / "prepared.json").write_text(json.dumps(prepared, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY

"$PY" "$ROOT/web-contract/report-renderer/report_renderer_phase2b.py" \
  --validation-json "$OUT/with_previous_session_date.json" \
  --prepared-media-json "$OUT/prepared.json" \
  --output-dir "$OUT/with_date" \
  --report comparison \
  --logo-pdf "" \
  --logo-svg "$ROOT/web-contract/report-production/assets/ScoutOnlyLogo.svg" \
  --pretty >/dev/null

"$PY" "$ROOT/web-contract/report-renderer/report_renderer_phase2b.py" \
  --validation-json "$OUT/without_previous_session_date.json" \
  --prepared-media-json "$OUT/prepared.json" \
  --output-dir "$OUT/without_date" \
  --report comparison \
  --logo-pdf "" \
  --logo-svg "$ROOT/web-contract/report-production/assets/ScoutOnlyLogo.svg" \
  --pretty >/dev/null

"$PY" - "$OUT" <<'PY'
from pathlib import Path
from pypdf import PdfReader
import json
import sys

root = Path(sys.argv[1])
with_plan = json.loads((root / "with_date" / "comparison" / "report_plan_comparison.json").read_text())
without_plan = json.loads((root / "without_date" / "comparison" / "report_plan_comparison.json").read_text())

def previous_entry(plan: dict) -> dict:
    return next(
        slot["entry"]
        for page in plan["pages"]
        if page["kind"] == "comparison_photo"
        for slot in page["slots"]
        if slot["role"] == "previous"
    )

assert previous_entry(with_plan)["captured_at_display"] == "August 18, 2026 \u2022 5:30 PM"
assert previous_entry(with_plan)["session_date_utc"] == "2026-08-18T21:30:00Z"
assert previous_entry(without_plan)["captured_at_display"] == "Unknown"

pdf = next((root / "with_date" / "comparison").glob("*.pdf"))
text = "\n".join(page.extract_text() or "" for page in PdfReader(str(pdf)).pages)
assert "Previous Session: August 18, 2026" in text
assert "Previous Session: Unknown" not in text
print("prior-session comparison PDF date regression passed")
PY
