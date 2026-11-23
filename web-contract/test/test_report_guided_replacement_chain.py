"""A reclassified Guided retake must replace the entire earlier photo chain."""

import importlib.util
import pathlib
import sys


module_path = pathlib.Path(__file__).resolve().parents[1] / "report-input" / "report_input_phase1.py"
spec = importlib.util.spec_from_file_location("report_input_phase1", module_path)
report = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = report
spec.loader.exec_module(report)


def source(session_id, mode, shot):
    return {
        "row": {"id": session_id, "session_id": session_id},
        "payload": {},
        "metadata": {
            "sessionID": session_id,
            "startedAt": "2026-11-22T00:00:00Z",
            "endedAt": "2026-11-22T00:01:00Z",
            "fullDocumentationMode": mode,
            "shots": [shot],
        },
        "session_type": "full_documentation",
    }


def guided(shot_id, session_id, elevation, detail, supersedes=None):
    return {
        "shotID": shot_id,
        "sessionID": session_id,
        "building": "B1",
        "elevation": elevation,
        "detailType": detail,
        "angleIndex": 1,
        "isGuided": True,
        "captureKind": "retake",
        "createdAt": "2026-11-22T00:00:30Z",
        "supersedesShotID": supersedes,
    }


sessions = [f"10000000-0000-0000-0000-00000000000{i}" for i in range(1, 4)]
shots = [f"20000000-0000-0000-0000-00000000000{i}" for i in range(1, 4)]
sources = [
    source(sessions[0], "complete_capture", guided(shots[0], sessions[0], "North", "Entry / Porch")),
    source(sessions[1], "follow_up", guided(shots[1], sessions[1], "South", "Roofline", shots[0])),
    source(sessions[2], "follow_up", guided(shots[2], sessions[2], "East", "Elevation", shots[1])),
]

composed = report.compose_punchlist_history(sources, report.StorageProbe(None, None))
photo_ids = [entry["shot_id"] for entry in composed["entries"] if entry["kind"] == "photo"]
assert photo_ids == [shots[2]], photo_ids

# Existing QA data predates the iOS lineage fix. Its immutable snapshot has no
# link on the newest photo, but the scoped operational repair marks the older
# photo superseded. A fresh report must still omit it.
legacy_sources = [*sources[:2], source(sessions[2], "follow_up",
    guided(shots[2], sessions[2], "East", "Elevation"))]
legacy = report.compose_punchlist_history(legacy_sources, report.StorageProbe(None, None))
report.apply_operational_guided_shots(legacy, {
    shots[0]: {"lifecycle_state": "superseded"},
    shots[1]: {"lifecycle_state": "superseded"},
    shots[2]: {"lifecycle_state": "active"},
})
legacy_photo_ids = [entry["shot_id"] for entry in legacy["entries"] if entry["kind"] == "photo"]
assert legacy_photo_ids == [shots[2]], legacy_photo_ids
print("guided replacement chain collapses to the newest photo")
