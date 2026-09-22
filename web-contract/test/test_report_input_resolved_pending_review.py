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


if __name__ == "__main__":
    unittest.main()
