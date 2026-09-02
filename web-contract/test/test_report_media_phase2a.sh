#!/usr/bin/env zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="/Users/brian/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
OUT="$(mktemp -d)"

"$PYTHON" - <<'PY' "$OUT/original.jpg"
from PIL import Image
import sys

image = Image.new("RGB", (640, 480), (72, 112, 166))
for x in range(640):
    for y in range(480):
        if (x // 40 + y // 40) % 2 == 0:
            image.putpixel((x, y), (92, 132, 186))
image.save(sys.argv[1], "JPEG", quality=92)
PY

"$PYTHON" - "$ROOT" "$OUT" <<'PY'
import importlib.util
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
module_path = root / "report-media" / "report_media_phase2a.py"
spec = importlib.util.spec_from_file_location("phase2a", module_path)
phase2a = importlib.util.module_from_spec(spec)
sys.modules["phase2a"] = phase2a
spec.loader.exec_module(phase2a)

out = pathlib.Path(sys.argv[2])
item = phase2a.MediaItem(
    role="current",
    shot_id="fixture-shot",
    session_id="fixture-session",
    source_bucket="fixture",
    source_path="fixture/original.jpg",
    source_filename="original.jpg",
    building="B1",
    elevation="North",
    detail_type="Overview",
    angle_index=2,
    shot_key="A2",
    captured_at_utc="2026-08-21T12:00:00Z",
    session_completed_at_utc=None,
    session_exported_at_utc=None,
    session_ended_at_utc=None,
    is_flagged=True,
    is_resolved_in_session=False,
)
first = phase2a.prepare_image(item, out / "original.jpg", out / "first.jpg", out)
second = phase2a.prepare_image(item, out / "original.jpg", out / "second.jpg", out)
assert first["prepared_width"] == 640
assert first["prepared_height"] == 480
assert first["flag_resolved_state_applied"] == "flagged"
assert first["prepared_media_mime_type"] == "image/jpeg"
assert first["deterministic_content_hash"] == second["deterministic_content_hash"]
assert phase2a.format_local_date("2026-08-24T01:51:00Z") == "Aug 23, 2026"
stamp_text, stamp_warnings = phase2a.make_stamp_text(
    phase2a.MediaItem(
        role="current",
        shot_id="rollover-shot",
        session_id="rollover-session",
        source_bucket="fixture",
        source_path="fixture/original.jpg",
        source_filename="original.jpg",
        building="B1",
        elevation="North",
        detail_type="Overview",
        angle_index=1,
        shot_key="A1",
        captured_at_utc="2026-08-24T01:51:00Z",
        session_completed_at_utc=None,
        session_exported_at_utc=None,
        session_ended_at_utc=None,
        is_flagged=False,
        is_resolved_in_session=False,
    )
)
assert "AUG 23, 2026" in stamp_text
assert not stamp_warnings
print("report-media phase2a fixture validation passed")
PY

rm -rf "$OUT"
