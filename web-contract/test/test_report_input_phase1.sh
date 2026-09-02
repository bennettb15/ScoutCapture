#!/usr/bin/env zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp)"

python3 "$ROOT/report-input/report_input_phase1.py" \
  --snapshot-row-fixture "$ROOT/report-input/fixtures/sample_snapshot_row.json" \
  --snapshot-payload-fixture "$ROOT/report-input/fixtures/sample_snapshot_payload.json" \
  --storage-fixture "$ROOT/report-input/fixtures/sample_storage_objects.json" \
  --canonical-fixture "$ROOT/report-input/fixtures/sample_canonical_history.json" \
  --output "$OUT" \
  --pretty

python3 - "$OUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["renderable_remotely"] is True
assert data["reports"]["property_report"]["generator_method"] == "generateSessionReport"
assert data["reports"]["property_report"]["photo_entry_count"] == 2
assert data["reports"]["property_report"]["skipped_placeholder_count"] == 1
assert data["reports"]["priority_report"]["generator_method"] == "generatePriorityItemsReport"
assert data["reports"]["priority_report"]["flagged_shot_count"] == 1
assert data["reports"]["priority_report"]["priority_counts"]["high"] == 1
assert data["reports"]["flagged_comparison"]["generator_method"] == "generateFlaggedComparisonReport"
assert data["reports"]["flagged_comparison"]["current_flagged_or_resolved_count"] == 1
item = data["comparisons"]["items"][0]
assert item["previous_shot_id"] == "50000000-0000-0000-0000-000000000099"
assert item["previous_session_completed_at_utc"] == "2026-07-20T15:00:00Z"
assert item["previous_captured_at_utc"] == "2026-07-20T14:22:00Z"
assert item["previous_media_exists"] is True
assert data["media"]["missing_count"] == 0
assert not data["gaps"], data["gaps"]

print("report-input phase1 fixture validation passed")
PY

python3 - "$ROOT" <<'PY'
import importlib.util
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
module_path = root / "report-input" / "report_input_phase1.py"
spec = importlib.util.spec_from_file_location("report_input_phase1", module_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

shot_id = "50000000-0000-0000-0000-000000000001"
assert module.sanitized_storage_filename(None, shot_id) == f"{shot_id}.jpg"
assert module.sanitized_storage_filename("", shot_id) == f"{shot_id}.jpg"
assert module.sanitized_storage_filename("legacy/original.heic", shot_id) == "original.heic"

print("report-input storage filename fallback validation passed")
PY

rm "$OUT"
