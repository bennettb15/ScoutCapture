#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
INPUT_PATH = ROOT / "web-contract" / "report-input" / "report_input_phase1.py"

SPEC = importlib.util.spec_from_file_location("report_input_phase1", INPUT_PATH)
report_input = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["report_input_phase1"] = report_input
SPEC.loader.exec_module(report_input)


class ReportInputResolvedPendingReviewTests(unittest.TestCase):
    def test_pending_review_resolved_capture_is_resolved_report_evidence(self) -> None:
        shot = report_input.report_shot(
            {"sessionID": "session-1"},
            {
                "shotID": "shot-1",
                "building": "B1",
                "elevation": "North",
                "detailType": "Door",
                "angleIndex": 1,
                "issueStatus": "pending_review",
                "captureKind": "resolvedCapture",
                "isFlagged": True,
                "storagePath": "sessions/session-1/shot-1.jpg",
            },
            {},
            {"user_id": None, "email": None},
        )

        self.assertIs(True, shot["is_resolved_in_session"])
        self.assertEqual("pending_review", shot["issue_status"])
        self.assertEqual("resolvedCapture", shot["capture_kind"])

    def test_pending_review_issue_row_is_resolved_report_evidence(self) -> None:
        shot = report_input.report_shot(
            {"sessionID": "session-1"},
            {
                "shotID": "shot-1",
                "issueID": "issue-1",
                "building": "B1",
                "elevation": "North",
                "detailType": "Door",
                "angleIndex": 1,
                "isFlagged": True,
                "storagePath": "sessions/session-1/shot-1.jpg",
            },
            {
                "issue-1": {
                    "issueStatus": "pending_review",
                    "lastCaptureSessionId": "session-1",
                }
            },
            {"user_id": None, "email": None},
        )

        self.assertIs(True, shot["is_resolved_in_session"])

    def test_complete_capture_carries_pending_review_only_once(self) -> None:
        current = [{"shot_id": "current-1"}]
        history = [
            {"shot_id": "prior-pending", "issue_id": "issue-a", "issue_status": "pending_review"},
            {"shot_id": "prior-resolved", "issue_id": "issue-b", "issue_status": "resolved"},
            {"shot_id": "current-1", "issue_id": "issue-c", "issue_status": "pending_review"},
            {"shot_id": "prior-replaced", "issue_id": "issue-d", "issue_status": "pending_review"},
        ]
        current.append({"shot_id": "current-replacement", "issue_id": "issue-d"})
        carried = report_input.pending_review_carry_forward_photos(current, history)
        self.assertEqual([shot["shot_id"] for shot in carried], ["prior-pending"])


if __name__ == "__main__":
    unittest.main()
