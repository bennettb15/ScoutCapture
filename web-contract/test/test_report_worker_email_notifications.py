#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest
from types import SimpleNamespace
from typing import Any
from unittest.mock import patch


ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKER_PATH = ROOT / "web-contract" / "report-production" / "report_worker_cli.py"
SPEC = importlib.util.spec_from_file_location("report_worker_cli", WORKER_PATH)
worker = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(worker)


ORG_ID = "00000000-0000-0000-0000-000000000001"
OTHER_ORG_ID = "00000000-0000-0000-0000-000000000002"
PROPERTY_ID = "10000000-0000-0000-0000-000000000001"
OTHER_PROPERTY_ID = "10000000-0000-0000-0000-000000000002"
SESSION_ID = "20000000-0000-0000-0000-000000000001"
SNAPSHOT_ID = "30000000-0000-0000-0000-000000000001"
PACKAGE_ID = "40000000-0000-0000-0000-000000000001"


class FakeSupabaseClient:
    def __init__(self) -> None:
        self.environment = "local-test"
        self.tables: dict[str, list[dict[str, Any]]] = {
            "orgs": [{"id": ORG_ID, "name": "Test Organization", "deleted_at": None}],
            "org_memberships": [],
            "users_profile": [],
            "property_access_grants": [],
            "properties": [
                {
                    "id": PROPERTY_ID,
                    "org_id": ORG_ID,
                    "name": "Test New Property",
                    "address_line1": "123 Portal Way",
                    "address_line2": None,
                    "city": "Austin",
                    "state": "TX",
                    "postal_code": "78701",
                    "deleted_at": None,
                }
            ],
            "session_snapshots": [
                {
                    "id": SNAPSHOT_ID,
                    "org_id": ORG_ID,
                    "property_id": PROPERTY_ID,
                    "session_id": SESSION_ID,
                    "snapshot_kind": "completed",
                    "session_status": "completed",
                    "is_sealed": True,
                    "raw_session_json_sha256": "raw-session-sha",
                    "snapshot_payload_sha256": "snapshot-payload-sha",
                    "deleted_at": None,
                }
            ],
            "sessions": [
                {
                    "id": SESSION_ID,
                    "org_id": ORG_ID,
                    "property_id": PROPERTY_ID,
                    "status": "completed",
                    "is_sealed": True,
                    "exported_at": None,
                    "first_delivered_at": None,
                    "deleted_at": None,
                }
            ],
            "property_status": [
                {
                    "property_id": PROPERTY_ID,
                    "org_id": ORG_ID,
                    "status": "pending_export",
                    "active_session_id": None,
                    "draft_session_id": None,
                    "pending_export_session_id": SESSION_ID,
                    "last_exported_session_id": None,
                    "owner_user_id": None,
                    "owner_device_id": None,
                    "heartbeat_at": None,
                    "status_reason": "test:pending_export",
                }
            ],
            "report_packages": [],
            "report_package_files": [],
            worker.REPORT_READY_NOTIFICATION_TABLE: [],
            worker.REPORT_EMAIL_ORG_SETTINGS_TABLE: [],
            worker.REPORT_EMAIL_USER_PREFERENCES_TABLE: [],
        }
        self.uploads: list[dict[str, Any]] = []
        self.objects: set[tuple[str, str]] = set()
        self.upload_failures_remaining = 0

    def add_profile(self, user_id: str, email: str | None, full_name: str | None = None, deleted: bool = False) -> None:
        self.tables["users_profile"].append(
            {
                "id": user_id,
                "email": email,
                "full_name": full_name,
                "deleted_at": "2026-01-01T00:00:00Z" if deleted else None,
            }
        )

    def add_membership(
        self,
        user_id: str,
        role: str,
        org_id: str = ORG_ID,
        access_scope: str = "org",
        deleted: bool = False,
    ) -> None:
        self.tables["org_memberships"].append(
            {
                "user_id": user_id,
                "role": role,
                "org_id": org_id,
                "access_scope": access_scope,
                "deleted_at": "2026-01-01T00:00:00Z" if deleted else None,
            }
        )

    def add_property_grant(
        self,
        user_id: str,
        org_id: str = ORG_ID,
        property_id: str = PROPERTY_ID,
        deleted: bool = False,
    ) -> None:
        self.tables["property_access_grants"].append(
            {
                "user_id": user_id,
                "org_id": org_id,
                "property_id": property_id,
                "deleted_at": "2026-01-01T00:00:00Z" if deleted else None,
            }
        )

    def set_org_report_email_enabled(self, enabled: bool, org_id: str = ORG_ID) -> None:
        self.tables[worker.REPORT_EMAIL_ORG_SETTINGS_TABLE].append(
            {
                "org_id": org_id,
                "report_ready_enabled": enabled,
            }
        )

    def set_user_report_email_enabled(self, user_id: str, enabled: bool, org_id: str = ORG_ID) -> None:
        self.tables[worker.REPORT_EMAIL_USER_PREFERENCES_TABLE].append(
            {
                "org_id": org_id,
                "user_id": user_id,
                "report_ready_enabled": enabled,
            }
        )

    def _matches_query(self, row: dict[str, Any], query: dict[str, str]) -> bool:
        for key, value in query.items():
            if key in {"select", "limit", "order"}:
                continue
            if value.startswith("eq."):
                expected = value[3:]
                if expected.lower() in {"true", "false"}:
                    if bool(row.get(key)) != (expected.lower() == "true"):
                        return False
                elif str(row.get(key)) != expected:
                    return False
            elif value.startswith("in.(") and value.endswith(")"):
                expected_values = set(value[4:-1].split(","))
                if str(row.get(key)) not in expected_values:
                    return False
            elif value.startswith("not.like.") and value.endswith("*"):
                if str(row.get(key) or "").startswith(value[len("not.like."):-1]):
                    return False
            elif value == "is.null":
                if row.get(key) is not None:
                    return False
            else:
                raise AssertionError(f"Unsupported fake query: {key}={value}")
        return True

    def select(self, table: str, query: dict[str, str]) -> list[dict[str, Any]]:
        rows = [dict(row) for row in self.tables.get(table, [])]
        rows = [row for row in rows if self._matches_query(row, query)]
        if "limit" in query:
            rows = rows[: int(query["limit"])]
        return rows

    def insert_ignore(self, table: str, rows: list[dict[str, Any]], on_conflict: str) -> list[dict[str, Any]]:
        inserted = []
        conflict_keys = on_conflict.split(",")
        target = self.tables.setdefault(table, [])
        for row in rows:
            duplicate = any(all(existing.get(key) == row.get(key) for key in conflict_keys) for existing in target)
            if duplicate:
                continue
            stored = dict(row)
            stored["id"] = f"notification-{len(target) + 1}"
            stored.setdefault("attempt_count", 0)
            stored.setdefault("last_error", None)
            stored.setdefault("provider_message_id", None)
            target.append(stored)
            inserted.append(dict(stored))
        return inserted

    def patch(self, table: str, query: dict[str, str], row: dict[str, Any]) -> list[dict[str, Any]]:
        rows = self.tables[table]
        patched = []
        for existing in rows:
            if self._matches_query(existing, query):
                existing.update(row)
                patched.append(dict(existing))
        return patched

    def insert(self, table: str, row: dict[str, Any]) -> dict[str, Any]:
        stored = dict(row)
        if table == "report_package_files":
            stored.setdefault("id", f"file-{len(self.tables.setdefault(table, [])) + 1}")
        else:
            stored.setdefault("id", PACKAGE_ID)
        self.tables.setdefault(table, []).append(stored)
        return dict(stored)

    def upload_object(self, bucket: str, path: str, source_path: pathlib.Path, content_type: str, upsert: bool = True) -> None:
        if self.upload_failures_remaining > 0:
            self.upload_failures_remaining -= 1
            raise TimeoutError("The read operation timed out")
        self.uploads.append(
            {
                "bucket": bucket,
                "path": path,
                "source_path": str(source_path),
                "content_type": content_type,
            }
        )
        self.objects.add((bucket, path))

    def object_exists(self, bucket: str, path: str) -> bool:
        return (bucket, path) in self.objects

    def delete_object(self, bucket: str, path: str) -> None:
        return None


class FakeEmailClient:
    def __init__(self, fail: bool = False) -> None:
        self.fail = fail
        self.sent: list[dict[str, Any]] = []
        self.portal_base_url = "https://reports.example.test"

    def send(
        self,
        recipient: dict[str, Any],
        context: dict[str, str | None],
        package: dict[str, Any],
        idempotency_key: str,
    ) -> str:
        if self.fail:
            raise worker.WorkerError("forced email failure")
        self.sent.append(
            {
                "recipient": recipient,
                "context": context,
                "package": package,
                "idempotency_key": idempotency_key,
            }
        )
        return f"message-{len(self.sent)}"


def package(status: str = "ready") -> dict[str, Any]:
    return {
        "id": PACKAGE_ID,
        "org_id": ORG_ID,
        "property_id": PROPERTY_ID,
        "session_id": SESSION_ID,
        "snapshot_id": SNAPSHOT_ID,
        "status": status,
        "session_completed_at": "2026-09-07T14:30:00Z",
    }


def validation() -> dict[str, Any]:
    return {
        "inputs": {
            "session": {
                "session_id": SESSION_ID,
                "org_id": ORG_ID,
                "property_id": PROPERTY_ID,
                "property_name": "Test New Property",
                "property_address": "123 Portal Way, Austin, TX",
                "ended_at_utc": "2026-09-07T14:30:00Z",
                "session_type": "full_documentation",
            }
        }
    }


def snapshot_row() -> dict[str, Any]:
    return {
        "id": SNAPSHOT_ID,
        "org_id": ORG_ID,
        "property_id": PROPERTY_ID,
        "session_id": SESSION_ID,
    }


def worker_args(output_dir: pathlib.Path) -> SimpleNamespace:
    return SimpleNamespace(
        output_dir=str(output_dir),
        allow_weather_fetch=False,
        retention_mode="dry-run",
        pretty=True,
    )


def fake_worker_run_step(session_type: str, rendered_report_types: list[str]):
    def run_step(cmd: list[str], cwd: pathlib.Path, env: dict[str, str]) -> None:
        joined = " ".join(cmd)
        if "report_input_phase1.py" in joined:
            output = pathlib.Path(cmd[cmd.index("--output") + 1])
            worker.write_json(
                output,
                {
                    "source_snapshot_id": SNAPSHOT_ID,
                    "source_provenance": {"source_snapshots": [{"snapshot_id": SNAPSHOT_ID, "session_id": SESSION_ID}]},
                    "session_type": session_type,
                    "sessionType": session_type,
                    "renderable_remotely": True,
                    "media": {"missing_count": 0},
                    "inputs": {
                        "session": {
                            "session_id": SESSION_ID,
                            "org_id": ORG_ID,
                            "property_id": PROPERTY_ID,
                            "property_name": "Test New Property",
                            "property_address": "123 Portal Way, Austin, TX",
                            "started_at_utc": "2026-09-07T14:00:00Z",
                            "ended_at_utc": "2026-09-07T14:30:00Z",
                            "session_type": session_type,
                            "sessionType": session_type,
                        },
                        "ordered_shots": [
                            {
                                "shot_id": "shot-1",
                                "session_id": SESSION_ID,
                                "captured_by_user_id": "field-user",
                                "captured_by_email": "field@example.test",
                            }
                        ],
                    },
                },
            )
            return
        if "report_media_phase2a.py" in joined:
            output_dir = pathlib.Path(cmd[cmd.index("--output-dir") + 1])
            worker.write_json(
                output_dir / "prepared_report_media.json",
                {
                    "errors": [],
                    "items": [
                        {
                            "role": "current",
                            "shot_id": "shot-1",
                            "session_id": SESSION_ID,
                            "source_storage_bucket": "scoutcapture-originals",
                            "source_storage_path": "sessions/test/shot-1.heic",
                            "uploaded_by_user_id": "field-user",
                            "uploaded_by_email": "field@example.test",
                        }
                    ],
                },
            )
            return
        if "report_renderer_phase2b.py" in joined:
            output_dir = pathlib.Path(cmd[cmd.index("--output-dir") + 1])
            reports = []
            for report_type in rendered_report_types:
                report_dir = output_dir / report_type
                report_dir.mkdir(parents=True, exist_ok=True)
                pdf_path = report_dir / f"{report_type}.pdf"
                pdf_path.write_bytes(f"%PDF-1.4\n% {report_type}\n".encode("utf-8"))
                reports.append(
                    {
                        "report_type": report_type,
                        "output_filename": pdf_path.name,
                        "pdf_path": str(pdf_path),
                        "pdf_sha256": worker.sha256_file(pdf_path),
                        "page_count": 1,
                        "report_plan_sha256": f"{report_type}-plan-sha",
                        "validation_failures": [],
                    }
                )
            worker.write_json(
                output_dir / "phase2c_summary.json",
                {
                    "generator_version": worker.RENDERER_VERSION,
                    "session_type": session_type,
                    "sessionType": session_type,
                    "reports": reports,
                    "skipped_reports": [],
                    "weather": {},
                },
            )
            return
        raise AssertionError(f"Unexpected worker command: {joined}")

    return run_step


class ReportWorkerEmailNotificationTests(unittest.TestCase):
    def test_legacy_review_decisions_must_cover_the_exact_sealed_photos(self) -> None:
        first = {"observation_id": "issue-1", "shot_id": "photo-1"}
        second = {"observation_id": "issue-2", "shot_id": "photo-2"}
        validation = {
            "source_provenance": {"legacy_pending_resolution_photos": [first, second]},
            "inputs": {"session": {}, "ordered_shots": [{"issue_id": "issue-1", "shot_id": "photo-1"},
                                                         {"issue_id": "issue-2", "shot_id": "photo-2"}]},
        }
        first_decision = {**first, "legacy": True, "decision_activity_id": "approval", "status": "resolved"}
        second_decision = {**second, "legacy": True, "decision_activity_id": "rejection", "status": "active"}

        for invalid in (
            [first_decision],
            [first_decision, {**second_decision, "observation_id": "other-issue"}],
            [first_decision, {**second_decision, "decision_activity_id": None}],
            [first_decision, first_decision],
        ):
            with self.assertRaisesRegex(worker.WorkerError, "sealed source snapshot"):
                worker.apply_reviewed_resolutions(validation, invalid)

        worker.apply_reviewed_resolutions(validation, [first_decision, second_decision])
        self.assertEqual(
            ["resolved", "active"],
            [shot["reviewed_resolution_status"] for shot in validation["inputs"]["ordered_shots"]],
        )

    def test_reviewed_request_cli_accepts_a_scoped_remote_request_without_allowlist(self) -> None:
        request_id = "50000000-0000-0000-0000-000000000001"
        argv = ["report_worker_cli.py", "--allow-remote-validation", "--expected-project-ref", "review-test",
                "--reviewed-report-request-id", request_id]
        env = {"SUPABASE_URL": "https://review-test.supabase.co", "SUPABASE_SERVICE_ROLE_KEY": "fake"}
        with patch.dict(os.environ, env, clear=True), patch.object(sys, "argv", argv), \
             patch.object(worker, "process_reviewed_report_request") as process:
            self.assertEqual(0, worker.main())
        process.assert_called_once()
        args, client, _, dispatched_id = process.call_args.args
        self.assertEqual("remote-validation", client.environment)
        self.assertEqual(request_id, dispatched_id)
        self.assertEqual([], args.allow_session_id)

    def test_reviewed_request_cli_preserves_remote_project_and_id_guards(self) -> None:
        request_id = "50000000-0000-0000-0000-000000000001"
        env = {"SUPABASE_URL": "https://review-test.supabase.co", "SUPABASE_SERVICE_ROLE_KEY": "fake"}
        for flags, message in (
            (["--reviewed-report-request-id", request_id], "without --allow-remote-validation"),
            (["--allow-remote-validation", "--expected-project-ref", "other",
              "--reviewed-report-request-id", request_id], "does not match"),
            (["--allow-remote-validation", "--expected-project-ref", "review-test",
              "--reviewed-report-request-id", "invalid"], "Invalid reviewed report request ID"),
            (["--allow-remote-validation", "--expected-project-ref", "review-test",
              "--session-id", SESSION_ID], "Remote validation requires at least one"),
        ):
            with self.subTest(flags=flags), patch.dict(os.environ, env, clear=True), \
                 patch.object(sys, "argv", ["report_worker_cli.py", *flags]), \
                 patch.object(worker, "process_reviewed_report_request") as process:
                with self.assertRaisesRegex(worker.WorkerError, message):
                    worker.main()
                process.assert_not_called()

    def test_reviewed_request_creates_separate_ready_package_and_is_idempotent(self) -> None:
        client = FakeSupabaseClient()
        original = package()
        original["id"] = "40000000-0000-0000-0000-000000000002"
        original["idempotency_key"] = "original"
        client.tables["report_packages"].append(dict(original))
        request = {
            "id": "50000000-0000-0000-0000-000000000001",
            "org_id": ORG_ID, "property_id": PROPERTY_ID, "source_package_id": original["id"],
            "status": "queued", "review_outcomes": [
                {"observation_id": "issue-1", "shot_id": "shot-1", "status": "active"}
            ],
        }
        client.tables["reviewed_report_requests"] = [request]
        fake_step = fake_worker_run_step("full_documentation", ["property", "priority", "comparison"])

        def run_step(cmd, cwd, env):
            fake_step(cmd, cwd, env)
            if any("report_input_phase1.py" in part for part in cmd):
                path = pathlib.Path(cmd[cmd.index("--output") + 1])
                payload = worker.read_json(path)
                payload["inputs"]["ordered_shots"][0].update(issue_id="issue-1", issue_status="pending_review")
                worker.write_json(path, payload)

        with tempfile.TemporaryDirectory() as tmp, patch.object(worker, "run_step", side_effect=run_step), \
                patch.object(worker, "send_report_ready_notifications") as email, \
                patch.object(worker, "mark_fast_lane_report_delivered") as delivery:
            args = worker_args(pathlib.Path(tmp))
            result = worker.process_reviewed_report_request(args, client, ROOT, request["id"])
            replay = worker.process_reviewed_report_request(args, client, ROOT, request["id"])
            email.assert_not_called()
            delivery.assert_not_called()
            rendered = worker.read_json(pathlib.Path(result["validation_json"]))
            self.assertEqual("active", rendered["inputs"]["ordered_shots"][0]["reviewed_resolution_status"])

        self.assertEqual(original, client.tables["report_packages"][0])
        self.assertEqual(2, len(client.tables["report_packages"]))
        self.assertEqual(3, len(client.uploads))
        self.assertTrue(all(f"/packages/{PACKAGE_ID}/" in row["path"] for row in client.uploads))
        self.assertEqual("ready", replay["status"])
        self.assertEqual(PACKAGE_ID, replay["result_package_id"])
        reviewed = client.tables["report_packages"][1]
        self.assertEqual("regenerated", reviewed["generation_trigger"])
        self.assertEqual("reviewed", reviewed["manifest"]["report_variant"])
        self.assertEqual(original["id"], reviewed["manifest"]["source_package_id"])
        self.assertEqual(request["id"], reviewed["manifest"]["reviewed_report_request_id"])

    def test_current_property_report_uses_exact_decisions_and_rechecks_before_publication(self) -> None:
        original = {**package(), "id": "latest-automatic"}
        request = {
            "id": "current-request", "org_id": ORG_ID, "property_id": PROPERTY_ID, "status": "queued",
            "source_package_id": original["id"], "report_scope": "current_property", "current_state_hash": "initial",
            "current_issue_states": [
                {"observation_id": "angle-2", "status": "pending_review"},
                {"observation_id": "angle-3", "status": "resolved"},
            ],
            "review_outcomes": [
                {"observation_id": "angle-3", "shot_id": "approved-photo", "status": "resolved",
                 "decision_activity_id": "older-approval", "snapshot_id": "old-snapshot", "session_id": "old-session"},
            ],
        }
        fake_step = fake_worker_run_step("punchlist_visit", ["property", "priority", "comparison"])

        def run_step(cmd, cwd, env):
            fake_step(cmd, cwd, env)
            if not any("report_input_phase1.py" in part for part in cmd):
                return
            self.assertIn("--current-property-review", cmd)
            output = pathlib.Path(cmd[cmd.index("--output") + 1])
            payload = worker.read_json(output)
            latest_photo = {"shot_id": "later-completion", "issue_id": "angle-2", "issue_status": "resolved",
                            "capture_kind": "resolved_capture", "source_shot_session_id": SESSION_ID}
            approved_photo = {"shot_id": "approved-photo", "issue_id": "angle-3", "issue_status": "pending_review",
                              "capture_kind": "resolved_capture", "source_shot_session_id": "old-session"}
            payload["source_provenance"]["source_snapshots"].append({"snapshot_id": "old-snapshot", "session_id": "old-session"})
            payload["inputs"]["ordered_shots"] = [latest_photo, approved_photo]
            payload["inputs"]["punchlist_shots"] = [latest_photo, approved_photo]
            worker.write_json(output, payload)

        for changed in (False, True):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as tmp:
                client = FakeSupabaseClient()
                client.tables["report_packages"] = [dict(original)]
                client.tables["reviewed_report_requests"] = [dict(request)]
                state = {"package_id": original["id"], "state_hash": "initial", "unresolved_count": 1}
                final = {**state, "state_hash": "changed"} if changed else state
                with patch.object(worker, "run_step", side_effect=run_step), \
                     patch.object(client, "rpc", create=True, side_effect=[state, state, final]), \
                     patch.object(worker, "send_report_ready_notifications") as email, \
                     patch.object(worker, "mark_fast_lane_report_delivered") as delivery:
                    args = worker_args(pathlib.Path(tmp))
                    if changed:
                        with self.assertRaisesRegex(worker.WorkerError, "current property report changed"):
                            worker.process_reviewed_report_request(args, client, ROOT, request["id"])
                    else:
                        result = worker.process_reviewed_report_request(args, client, ROOT, request["id"])
                        validated = worker.read_json(pathlib.Path(result["validation_json"]))
                        self.assertEqual([("later-completion", "pending_review"), ("approved-photo", "resolved")], [
                            (shot["shot_id"], shot["issue_status"]) for shot in validated["inputs"]["punchlist_shots"]
                        ])
                        self.assertEqual(request["review_outcomes"], validated["source_provenance"]["reviewed_resolution_outcomes"])
                    email.assert_not_called()
                    delivery.assert_not_called()
                self.assertEqual(original, client.tables["report_packages"][0])
                status = "failed" if changed else "ready"
                self.assertEqual(status, client.tables["reviewed_report_requests"][0]["status"])
                self.assertEqual(status, client.tables["report_packages"][1]["status"])

    def test_current_property_report_rejects_a_status_or_photo_mismatch(self) -> None:
        shot = {"shot_id": "sealed-photo", "issue_id": "issue", "issue_status": "active",
                "capture_kind": "follow_up_capture", "source_shot_session_id": "visit"}
        decision = {"shot_id": "different-photo", "observation_id": "issue", "status": "resolved",
                    "snapshot_id": "sealed", "session_id": "visit", "decision_activity_id": "approval"}
        for status, photo, message in (
            ("unknown", shot, "issues do not match"),
        ):
            with self.subTest(status=status, photo=photo):
                validation = {"inputs": {"punchlist_shots": [photo], "session": {}},
                              "source_provenance": {"source_snapshots": [{"snapshot_id": "sealed", "session_id": "visit"}]}}
                request = {"current_issue_states": [{"observation_id": "issue", "status": status}],
                           "review_outcomes": [decision], "current_state_hash": "hash"}
                with self.assertRaisesRegex(worker.WorkerError, message):
                    worker.apply_current_property_review(validation, request)

    def test_current_property_report_uses_live_status_after_review_setting_changed(self) -> None:
        for status, kind in (("resolved", "resolved_capture"), ("pending_review", "resolved_capture"),
                             ("active", "resolved_capture"),
                             ("resolved", "flagged_capture")):
            with self.subTest(status=status, kind=kind):
                photo = {"shot_id": "completion", "issue_id": "issue", "issue_status": "pending_review",
                         "capture_kind": kind, "source_shot_session_id": "visit"}
                validation = {"inputs": {"punchlist_shots": [photo], "ordered_shots": [photo], "session": {}},
                              "source_provenance": {"source_snapshots": [{"snapshot_id": "sealed", "session_id": "visit"}]}}
                request = {"current_issue_states": [{"observation_id": "issue", "status": status}],
                           "review_outcomes": [], "current_state_hash": "current"}
                worker.apply_current_property_review(validation, request)
                self.assertEqual(status, photo["issue_status"])
                self.assertEqual(status, photo["reviewed_resolution_status"])

    def test_current_reviewed_copy_uses_later_photo_and_reuses_exact_approval(self) -> None:
        client = FakeSupabaseClient()
        old_session = "20000000-0000-0000-0000-000000000002"
        old_snapshot = "30000000-0000-0000-0000-000000000002"
        original = {**package(), "id": "approval-source", "session_id": old_session,
                    "snapshot_id": old_snapshot, "session_completed_at": "2026-09-05T14:30:00Z"}
        historical_copy = {**original, "id": "historical-reviewed", "manifest": {"report_variant": "reviewed"}}
        content = {**package(), "id": "newer-automatic"}
        client.tables["report_packages"] = [dict(row) for row in (original, historical_copy, content)]
        client.tables["session_snapshots"].append(
            {**client.tables["session_snapshots"][0], "id": old_snapshot, "session_id": old_session}
        )
        client.tables["report_package_files"] = [
            {"package_id": content["id"], "org_id": ORG_ID, "property_id": PROPERTY_ID, "report_type": report_type}
            for report_type in ("property_report", "flagged_observations", "flagged_comparison")
        ]
        approval = {"shot_id": "angle-3-approved", "observation_id": "angle-3", "status": "resolved",
                    "legacy": True, "decision_activity_id": "approval"}
        request = {"id": "review-request", "org_id": ORG_ID, "property_id": PROPERTY_ID, "status": "ready",
                   "source_package_id": original["id"], "result_package_id": historical_copy["id"],
                   "review_outcomes": [approval]}
        client.tables["reviewed_report_requests"] = [dict(request)]
        fake_step = fake_worker_run_step("punchlist_visit", ["property", "priority", "comparison"])
        inputs_read = []

        def run_step(cmd, cwd, env):
            fake_step(cmd, cwd, env)
            if not any("report_input_phase1.py" in part for part in cmd):
                return
            source_id = cmd[cmd.index("--snapshot-id") + 1]
            inputs_read.append(source_id)
            output = pathlib.Path(cmd[cmd.index("--output") + 1])
            payload = worker.read_json(output)
            angle_3 = {"shot_id": "angle-3-approved", "issue_id": "angle-3", "issue_status": "pending_review"}
            if source_id == old_snapshot:
                self.assertIn("--legacy-review-source", cmd)
                payload["source_snapshot_id"] = old_snapshot
                payload["inputs"]["session"]["session_id"] = old_session
                payload["source_provenance"]["legacy_pending_resolution_photos"] = [
                    {"shot_id": angle_3["shot_id"], "observation_id": angle_3["issue_id"]}
                ]
                angle_2 = {"shot_id": "angle-2-old", "issue_id": "angle-2", "issue_status": "active"}
            else:
                self.assertIn("--verify-sealed-source", cmd)
                self.assertIn("--snapshot-history-only", cmd)
                angle_2 = {"shot_id": "angle-2-new", "issue_id": "angle-2", "issue_status": "resolved"}
            payload["inputs"]["ordered_shots"] = [angle_2, angle_3]
            payload["inputs"]["punchlist_shots"] = [angle_2, angle_3]
            worker.write_json(output, payload)

        with tempfile.TemporaryDirectory() as tmp, patch.object(worker, "run_step", side_effect=run_step), \
                patch.object(worker, "send_report_ready_notifications") as email, \
                patch.object(worker, "mark_fast_lane_report_delivered") as delivery:
            args = worker_args(pathlib.Path(tmp))
            result = worker.process_reviewed_current_copy(args, client, ROOT, request["id"], content["id"])
            replay = worker.process_reviewed_current_copy(args, client, ROOT, request["id"], content["id"])
            rendered = worker.read_json(pathlib.Path(result["validation_json"]))
            self.assertEqual([("angle-2-new", "resolved"), ("angle-3-approved", "resolved")], [
                (shot["shot_id"], shot["issue_status"]) for shot in rendered["inputs"]["punchlist_shots"]
            ])
            email.assert_not_called()
            delivery.assert_not_called()

        self.assertEqual([old_snapshot, SNAPSHOT_ID] * 2, inputs_read)
        self.assertEqual([request], client.tables["reviewed_report_requests"])
        self.assertEqual([original, historical_copy, content], client.tables["report_packages"][:3])
        reviewed = client.tables["report_packages"][3]
        self.assertEqual(SNAPSHOT_ID, reviewed["snapshot_id"])
        self.assertEqual(content["id"], reviewed["manifest"]["content_package_id"])
        self.assertEqual(original["id"], reviewed["manifest"]["source_package_id"])
        self.assertEqual(old_snapshot, reviewed["manifest"]["source_provenance"]["review_decision_snapshot_id"])
        self.assertEqual("already_ready", replay["package_action"])
        self.assertEqual(3, len(client.uploads))

    def test_current_reviewed_copy_rejects_a_replaced_or_unreviewed_photo(self) -> None:
        outcome = {"shot_id": "approved-photo", "observation_id": "approved-issue", "status": "resolved"}
        source = {"source_snapshot_id": "old", "inputs": {"punchlist_shots": [
            {"shot_id": "approved-photo", "issue_id": "approved-issue", "issue_status": "pending_review"}
        ]}}
        for shots, error in (
            ([{"shot_id": "new-photo", "issue_id": "approved-issue"}], "missing an exact reviewed photo"),
            ([{"shot_id": "approved-photo", "issue_id": "approved-issue"},
              {"shot_id": "unreviewed", "issue_id": "another-issue", "issue_status": "pending_review"}],
             "pending photos without a review decision"),
        ):
            with self.subTest(error=error):
                candidate = {"session_type": "punchlist_visit", "inputs": {"session": {}, "punchlist_shots": shots}}
                with self.assertRaisesRegex(worker.WorkerError, error):
                    worker.apply_review_to_current_content(source, candidate, [outcome])

    def test_worker_uses_punchlist_renderer_for_punchlist_visits(self) -> None:
        payload = validation()
        payload["session_type"] = "punchlist_visit"
        payload["inputs"]["session"]["session_type"] = "punchlist_visit"

        self.assertEqual("punchlist_visit", worker.session_type(payload))
        self.assertEqual("punchlist", worker.renderer_report_arg(payload))

    def test_worker_uses_full_renderer_for_full_documentation(self) -> None:
        self.assertEqual("full_documentation", worker.session_type(validation()))
        self.assertEqual("all", worker.renderer_report_arg(validation()))

    def test_created_package_manifest_marks_punchlistSessionType(self) -> None:
        client = FakeSupabaseClient()
        payload = validation()
        payload["source_snapshot_id"] = SNAPSHOT_ID
        payload["session_type"] = "punchlist_visit"
        payload["inputs"]["session"]["session_id"] = SESSION_ID
        payload["inputs"]["session"]["session_type"] = "punchlist_visit"

        package_row, action = worker.get_or_create_package(
            client,
            payload,
            snapshot_row(),
            "2026-09-07T14:30:00Z",
        )

        self.assertEqual("created", action)
        self.assertEqual("punchlist_visit", package_row["manifest"]["sessionType"])
        self.assertEqual("punchlist_visit", package_row["manifest"]["session_type"])

    def test_punchlist_visit_package_skips_property_report(self) -> None:
        client = FakeSupabaseClient()
        original_run_step = worker.run_step
        with tempfile.TemporaryDirectory() as tmp:
            worker.run_step = fake_worker_run_step("punchlist_visit", ["priority", "comparison"])
            try:
                summary = worker.process_session(
                    worker_args(pathlib.Path(tmp)),
                    client,
                    ROOT,
                    SESSION_ID,
                    SNAPSHOT_ID,
                )
            finally:
                worker.run_step = original_run_step

        package_row = client.tables["report_packages"][0]
        package_report_types = [item["report_type"] for item in package_row["manifest"]["reports"]]
        file_report_types = [row["report_type"] for row in client.tables["report_package_files"]]
        upload_paths = [upload["path"] for upload in client.uploads]

        self.assertEqual("ready", package_row["status"])
        self.assertEqual("punchlist_visit", package_row["manifest"]["sessionType"])
        self.assertEqual("punchlist_visit", package_row["manifest"]["session_type"])
        self.assertEqual(["flagged_observations", "flagged_comparison"], package_report_types)
        self.assertEqual(["flagged_observations", "flagged_comparison"], file_report_types)
        self.assertEqual(["flagged_observations", "flagged_comparison"], [item["report_type"] for item in summary["uploaded_files"]])
        self.assertFalse(any("property_report.pdf" in path for path in upload_paths))
        self.assertNotIn("property_report", package_report_types)

    def test_punchlist_visit_package_accepts_punchlist_update_fallback(self) -> None:
        client = FakeSupabaseClient()
        original_run_step = worker.run_step
        with tempfile.TemporaryDirectory() as tmp:
            worker.run_step = fake_worker_run_step("punchlist_visit", ["punchlist_update"])
            try:
                summary = worker.process_session(
                    worker_args(pathlib.Path(tmp)),
                    client,
                    ROOT,
                    SESSION_ID,
                    SNAPSHOT_ID,
                )
            finally:
                worker.run_step = original_run_step

        package_row = client.tables["report_packages"][0]
        package_report_types = [item["report_type"] for item in package_row["manifest"]["reports"]]
        file_report_types = [row["report_type"] for row in client.tables["report_package_files"]]

        self.assertEqual("ready", package_row["status"])
        self.assertEqual("punchlist_visit", package_row["manifest"]["sessionType"])
        self.assertEqual(["punchlist_update"], package_report_types)
        self.assertEqual(["punchlist_update"], file_report_types)
        self.assertEqual(["punchlist_update"], [item["report_type"] for item in summary["uploaded_files"]])

    def test_ready_package_success_marks_session_and_property_exported(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("field-user", "field@example.test")
        client.add_membership("field-user", "field")
        original_run_step = worker.run_step
        original_resend = worker.ResendEmailClient

        class FakeResendEmailClient:
            @classmethod
            def from_env(cls) -> FakeEmailClient:
                return FakeEmailClient()

        with tempfile.TemporaryDirectory() as tmp:
            worker.run_step = fake_worker_run_step("full_documentation", ["property"])
            worker.ResendEmailClient = FakeResendEmailClient
            try:
                summary = worker.process_session(
                    worker_args(pathlib.Path(tmp)),
                    client,
                    ROOT,
                    SESSION_ID,
                    SNAPSHOT_ID,
                )
            finally:
                worker.run_step = original_run_step
                worker.ResendEmailClient = original_resend

        session_row = client.tables["sessions"][0]
        status_row = client.tables["property_status"][0]
        self.assertEqual("marked_exported", summary["delivery_status"]["action"])
        self.assertTrue(summary["delivery_status"]["success"])
        self.assertIsNotNone(session_row["exported_at"])
        self.assertIsNotNone(session_row["first_delivered_at"])
        self.assertEqual("exported", status_row["status"])
        self.assertIsNone(status_row["pending_export_session_id"])
        self.assertEqual(SESSION_ID, status_row["last_exported_session_id"])

    def test_email_failure_keeps_pending_export_retryable(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("field-user", "field@example.test")
        client.add_membership("field-user", "field")
        original_run_step = worker.run_step
        original_resend = worker.ResendEmailClient

        class FailingResendEmailClient:
            @classmethod
            def from_env(cls) -> FakeEmailClient:
                return FakeEmailClient(fail=True)

        with tempfile.TemporaryDirectory() as tmp:
            worker.run_step = fake_worker_run_step("full_documentation", ["property"])
            worker.ResendEmailClient = FailingResendEmailClient
            try:
                summary = worker.process_session(
                    worker_args(pathlib.Path(tmp)),
                    client,
                    ROOT,
                    SESSION_ID,
                    SNAPSHOT_ID,
                )
            finally:
                worker.run_step = original_run_step
                worker.ResendEmailClient = original_resend

        session_row = client.tables["sessions"][0]
        status_row = client.tables["property_status"][0]
        self.assertEqual("skipped_email_not_complete", summary["delivery_status"]["action"])
        self.assertFalse(summary["delivery_status"]["success"])
        self.assertIsNone(session_row["exported_at"])
        self.assertIsNone(session_row["first_delivered_at"])
        self.assertEqual("pending_export", status_row["status"])
        self.assertEqual(SESSION_ID, status_row["pending_export_session_id"])
        self.assertEqual(1, summary["email_notifications"]["failed_count"])

    def test_full_documentation_package_includes_property_report(self) -> None:
        client = FakeSupabaseClient()
        original_run_step = worker.run_step
        with tempfile.TemporaryDirectory() as tmp:
            worker.run_step = fake_worker_run_step("full_documentation", ["property", "priority", "comparison"])
            try:
                summary = worker.process_session(
                    worker_args(pathlib.Path(tmp)),
                    client,
                    ROOT,
                    SESSION_ID,
                    SNAPSHOT_ID,
                )
            finally:
                worker.run_step = original_run_step

        package_row = client.tables["report_packages"][0]
        package_report_types = [item["report_type"] for item in package_row["manifest"]["reports"]]
        file_report_types = [row["report_type"] for row in client.tables["report_package_files"]]

        self.assertEqual("ready", package_row["status"])
        self.assertEqual("full_documentation", package_row["manifest"]["sessionType"])
        self.assertEqual("full_documentation", package_row["manifest"]["session_type"])
        self.assertEqual(
            ["property_report", "flagged_observations", "flagged_comparison"],
            package_report_types,
        )
        self.assertEqual(
            ["property_report", "flagged_observations", "flagged_comparison"],
            file_report_types,
        )
        self.assertEqual(
            ["property_report", "flagged_observations", "flagged_comparison"],
            [item["report_type"] for item in summary["uploaded_files"]],
        )

    def test_punchlist_package_can_include_baseline_property_report(self) -> None:
        client = FakeSupabaseClient()
        original_run_step = worker.run_step
        with tempfile.TemporaryDirectory() as tmp:
            worker.run_step = fake_worker_run_step(
                "punchlist_visit", ["property", "priority", "comparison"])
            try:
                worker.process_session(worker_args(pathlib.Path(tmp)), client,
                                       ROOT, SESSION_ID, SNAPSHOT_ID)
            finally:
                worker.run_step = original_run_step
        manifest = client.tables["report_packages"][0]["manifest"]
        self.assertEqual(["property_report", "flagged_observations", "flagged_comparison"],
                         [row["report_type"] for row in manifest["reports"]])
        self.assertEqual(SNAPSHOT_ID, manifest["source_provenance"]["source_snapshots"][0]["snapshot_id"])

    def test_existing_pdf_is_never_overwritten(self) -> None:
        class ExistingPdfClient(FakeSupabaseClient):
            def object_exists(self, bucket, path):
                return True
            def download_object(self, bucket, path):
                return b"%PDF-1.4\nold content"
        client = ExistingPdfClient()
        with tempfile.TemporaryDirectory() as tmp:
            pdf = pathlib.Path(tmp) / "new.pdf"
            pdf.write_bytes(b"%PDF-1.4\nnew content")
            with self.assertRaisesRegex(worker.WorkerError, "Refusing to overwrite"):
                worker.upload_pdf_with_retry(client, worker.DELIVERABLES_BUCKET,
                                             "orgs/test/new.pdf", pdf)
        self.assertEqual([], client.uploads)

    def test_retention_cannot_delete_historical_pdfs(self) -> None:
        client = FakeSupabaseClient()
        with self.assertRaisesRegex(worker.WorkerError, "retention is disabled"):
            worker.apply_retention(client, [{"id": "older-package"}], "apply")
        self.assertEqual([], client.uploads)

    def test_pdf_upload_retries_transient_timeout(self) -> None:
        client = FakeSupabaseClient()
        client.upload_failures_remaining = 2
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = pathlib.Path(tmp) / "property.pdf"
            pdf_path.write_bytes(b"%PDF-1.4\n")
            worker.upload_pdf_with_retry(
                client,
                worker.DELIVERABLES_BUCKET,
                "orgs/test/properties/test/sessions/test/packages/test/pdfs/property_report.pdf",
                pdf_path,
                attempts=3,
                sleep_func=lambda _delay: None,
            )

        self.assertEqual(1, len(client.uploads))
        self.assertEqual(0, client.upload_failures_remaining)

    def test_pdf_upload_fails_only_after_retry_budget(self) -> None:
        client = FakeSupabaseClient()
        client.upload_failures_remaining = 3
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = pathlib.Path(tmp) / "property.pdf"
            pdf_path.write_bytes(b"%PDF-1.4\n")
            with self.assertRaisesRegex(worker.WorkerError, "PDF upload failed after 3 attempts"):
                worker.upload_pdf_with_retry(
                    client,
                    worker.DELIVERABLES_BUCKET,
                    "orgs/test/properties/test/sessions/test/packages/test/pdfs/property_report.pdf",
                    pdf_path,
                    attempts=3,
                    sleep_func=lambda _delay: None,
                )

        self.assertEqual(0, len(client.uploads))

    def test_ready_package_exists_requires_active_file_row_and_storage_object(self) -> None:
        client = FakeSupabaseClient()
        client.tables["report_packages"].append(package())

        self.assertFalse(worker.ready_package_exists(client, SNAPSHOT_ID))

        storage_path = worker.path_for_pdf(
            ORG_ID,
            PROPERTY_ID,
            SESSION_ID,
            PACKAGE_ID,
            "property_report",
        )
        client.tables["report_package_files"].append(
            {
                "id": "file-1",
                "package_id": PACKAGE_ID,
                "org_id": ORG_ID,
                "property_id": PROPERTY_ID,
                "session_id": SESSION_ID,
                "snapshot_id": SNAPSHOT_ID,
                "report_type": "property_report",
                "storage_bucket": worker.DELIVERABLES_BUCKET,
                "storage_path": storage_path,
                "mime_type": "application/pdf",
                "storage_deleted_at": None,
                "deleted_at": None,
            }
        )

        self.assertFalse(worker.ready_package_exists(client, SNAPSHOT_ID))
        client.objects.add((worker.DELIVERABLES_BUCKET, storage_path))
        self.assertTrue(worker.ready_package_exists(client, SNAPSHOT_ID))

    def test_recipient_scoping_excludes_inactive_and_unrelated_users(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("owner-user", "owner@example.test")
        client.add_profile("field-user", "field@example.test")
        client.add_profile("inactive-user", "inactive@example.test")
        client.add_profile("deleted-profile-user", "deleted@example.test", deleted=True)
        client.add_profile("other-org-user", "other@example.test")
        client.add_membership("owner-user", "owner")
        client.add_membership("field-user", "field")
        client.add_membership("inactive-user", "manager", deleted=True)
        client.add_membership("deleted-profile-user", "viewer")
        client.add_membership("other-org-user", "owner", org_id=OTHER_ORG_ID)

        recipients = worker.eligible_report_ready_recipients(client, package())

        self.assertEqual(["owner@example.test", "field@example.test"], [row["email"] for row in recipients])

    def test_global_email_disable_env_suppresses_recipients(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("owner-user", "owner@example.test")
        client.add_membership("owner-user", "owner")
        prior = os.environ.get("REPORT_EMAIL_NOTIFICATIONS_ENABLED")
        os.environ["REPORT_EMAIL_NOTIFICATIONS_ENABLED"] = "false"
        try:
            recipients = worker.eligible_report_ready_recipients(client, package())
        finally:
            if prior is None:
                os.environ.pop("REPORT_EMAIL_NOTIFICATIONS_ENABLED", None)
            else:
                os.environ["REPORT_EMAIL_NOTIFICATIONS_ENABLED"] = prior

        self.assertEqual([], recipients)

    def test_email_allowlist_limits_recipients(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("owner-user", "owner@example.test")
        client.add_profile("field-user", "field@example.test")
        client.add_membership("owner-user", "owner")
        client.add_membership("field-user", "field")
        prior = os.environ.get("REPORT_EMAIL_ALLOWLIST")
        os.environ["REPORT_EMAIL_ALLOWLIST"] = "field@example.test"
        try:
            recipients = worker.eligible_report_ready_recipients(client, package())
        finally:
            if prior is None:
                os.environ.pop("REPORT_EMAIL_ALLOWLIST", None)
            else:
                os.environ["REPORT_EMAIL_ALLOWLIST"] = prior

        self.assertEqual(["field@example.test"], [row["email"] for row in recipients])

    def test_org_email_disable_suppresses_recipients(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("owner-user", "owner@example.test")
        client.add_membership("owner-user", "owner")
        client.set_org_report_email_enabled(False)

        recipients = worker.eligible_report_ready_recipients(client, package())

        self.assertEqual([], recipients)

    def test_user_email_preference_excludes_disabled_member(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("owner-user", "owner@example.test")
        client.add_profile("field-user", "field@example.test")
        client.add_membership("owner-user", "owner")
        client.add_membership("field-user", "field")
        client.set_user_report_email_enabled("field-user", False)

        recipients = worker.eligible_report_ready_recipients(client, package())

        self.assertEqual(["owner@example.test"], [row["email"] for row in recipients])

    def test_property_access_scope_is_respected(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("viewer-with-access", "viewer-access@example.test")
        client.add_profile("viewer-without-access", "viewer-blocked@example.test")
        client.add_profile("owner-property-scoped", "owner@example.test")
        client.add_membership("viewer-with-access", "viewer", access_scope="property")
        client.add_membership("viewer-without-access", "viewer", access_scope="property")
        client.add_membership("owner-property-scoped", "owner", access_scope="property")
        client.add_property_grant("viewer-with-access")
        client.add_property_grant("viewer-without-access", property_id=OTHER_PROPERTY_ID)

        recipients = worker.eligible_report_ready_recipients(client, package())

        self.assertEqual(
            ["viewer-access@example.test", "owner@example.test"],
            [row["email"] for row in recipients],
        )

    def test_no_duplicate_sends_on_rerun(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("manager-user", "manager@example.test")
        client.add_membership("manager-user", "manager")
        sender = FakeEmailClient()

        first = worker.send_report_ready_notifications(client, package(), validation(), sender)
        second = worker.send_report_ready_notifications(client, package(), validation(), sender)

        self.assertEqual(1, first["inserted_count"])
        self.assertEqual(1, first["sent_count"])
        self.assertEqual(0, second["inserted_count"])
        self.assertEqual(0, second["sent_count"])
        self.assertEqual(1, len(sender.sent))

    def test_report_ready_email_uses_validation_session_type_when_package_missing_it(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("manager-user", "manager@example.test")
        client.add_membership("manager-user", "manager")
        payload = validation()
        payload["inputs"]["session"]["session_type"] = "punchlist_visit"
        payload["inputs"]["session"]["sessionType"] = "punchlist_visit"
        sender = FakeEmailClient()

        summary = worker.send_report_ready_notifications(client, package(), payload, sender)

        self.assertEqual(1, summary["sent_count"])
        sent_package = sender.sent[0]["package"]
        self.assertEqual("punchlist_visit", sent_package["sessionType"])
        self.assertEqual("punchlist_visit", sent_package["manifest"]["sessionType"])

    def test_report_ready_email_uses_snapshot_manifest_session_type_when_package_missing_it(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("manager-user", "manager@example.test")
        client.add_membership("manager-user", "manager")
        client.tables["session_snapshots"][0]["manifest"] = {
            "sessionType": "punchlist_visit",
            "session_type": "punchlist_visit",
        }
        payload = validation()
        payload["inputs"]["session"].pop("session_type", None)
        sender = FakeEmailClient()

        summary = worker.send_report_ready_notifications(client, package(), payload, sender)

        self.assertEqual(1, summary["sent_count"])
        sent_package = sender.sent[0]["package"]
        self.assertEqual("punchlist_visit", sent_package["sessionType"])
        self.assertEqual("punchlist_visit", sent_package["manifest"]["session_type"])

    def test_notification_only_after_package_ready(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("field-user", "field@example.test")
        client.add_membership("field-user", "field")
        sender = FakeEmailClient()

        summary = worker.send_report_ready_notifications(client, package(status="generating"), validation(), sender)

        self.assertFalse(summary["enabled"])
        self.assertEqual("package_not_ready", summary["error"])
        self.assertEqual(0, len(sender.sent))
        self.assertEqual([], client.tables[worker.REPORT_READY_NOTIFICATION_TABLE])

    def test_email_failure_does_not_raise_and_keeps_outbox_retryable(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("field-user", "field@example.test")
        client.add_membership("field-user", "field")
        sender = FakeEmailClient(fail=True)

        summary = worker.send_report_ready_notifications(client, package(), validation(), sender)

        notifications = client.tables[worker.REPORT_READY_NOTIFICATION_TABLE]
        self.assertEqual(1, summary["failed_count"])
        self.assertEqual("failed", notifications[0]["status"])
        self.assertIn("forced email failure", notifications[0]["last_error"])

    def test_drain_retries_failed_notification_for_ready_package(self) -> None:
        client = FakeSupabaseClient()
        client.add_profile("field-user", "field@example.test")
        client.add_membership("field-user", "field")
        client.tables["report_packages"].append(package())
        client.tables[worker.REPORT_READY_NOTIFICATION_TABLE].append(
            {
                "id": "notification-1",
                "org_id": ORG_ID,
                "property_id": PROPERTY_ID,
                "session_id": SESSION_ID,
                "snapshot_id": SNAPSHOT_ID,
                "package_id": PACKAGE_ID,
                "notification_type": worker.REPORT_READY_NOTIFICATION_TYPE,
                "recipient_user_id": "field-user",
                "recipient_email": "field@example.test",
                "recipient_name": None,
                "recipient_role": "field",
                "status": "failed",
                "provider": "resend",
                "provider_message_id": None,
                "idempotency_key": worker.report_ready_idempotency_key(PACKAGE_ID, "field-user"),
                "attempt_count": 1,
                "last_error": "previous provider error",
                "created_at": "2026-09-07T22:14:11Z",
            }
        )
        sender = FakeEmailClient()

        summary = worker.drain_report_ready_notifications(client, sender)

        notification = client.tables[worker.REPORT_READY_NOTIFICATION_TABLE][0]
        self.assertEqual(1, summary["package_count"])
        self.assertEqual("sent", notification["status"])
        self.assertEqual("message-1", notification["provider_message_id"])
        self.assertEqual(1, len(sender.sent))

    def test_reports_portal_link_uses_reports_path(self) -> None:
        self.assertEqual(
            "https://scoutclear.com/reports?"
            "orgId=00000000-0000-0000-0000-000000000001&"
            "propertyId=10000000-0000-0000-0000-000000000001&"
            "sessionId=20000000-0000-0000-0000-000000000001&"
            "packageId=40000000-0000-0000-0000-000000000001",
            worker.reports_portal_link("https://scoutclear.com", package()),
        )
        self.assertEqual(
            "https://scoutclear.com/reports?"
            "orgId=00000000-0000-0000-0000-000000000001&"
            "propertyId=10000000-0000-0000-0000-000000000001&"
            "sessionId=20000000-0000-0000-0000-000000000001&"
            "packageId=40000000-0000-0000-0000-000000000001",
            worker.reports_portal_link("https://scoutclear.com/reports", package()),
        )

    def test_session_datetime_uses_eastern_time(self) -> None:
        context = worker.report_ready_email_context(FakeSupabaseClient(), package(), validation())

        self.assertEqual("Sep 7, 2026 at 10:30 AM ET", context["session_datetime"])
        self.assertNotIn("UTC", context["session_datetime"] or "")

    def test_resend_request_sets_worker_user_agent_and_idempotency_key(self) -> None:
        captured: dict[str, Any] = {}

        class FakeResponse:
            def __enter__(self) -> "FakeResponse":
                return self

            def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
                return None

            def read(self) -> bytes:
                return b'{"id":"resend-message-id"}'

        def fake_urlopen(request: Any, timeout: int = 0) -> FakeResponse:
            captured["url"] = request.full_url
            captured["headers"] = dict(request.header_items())
            captured["payload"] = json.loads(request.data.decode("utf-8"))
            captured["timeout"] = timeout
            return FakeResponse()

        original_urlopen = worker.urllib.request.urlopen
        worker.urllib.request.urlopen = fake_urlopen
        try:
            client = worker.ResendEmailClient(
                api_key="test-api-key",
                from_email="reports@example.test",
                portal_base_url="https://reports.example.test",
            )
            message_id = client.send(
                {"email": "recipient@example.test"},
                {
                    "property_name": "Test New Property",
                    "property_address": "123 Portal Way",
                    "session_datetime": "Sep 7, 2026 at 6:14 PM ET",
                },
                package(),
                "report-package-ready-idempotency-key",
            )
        finally:
            worker.urllib.request.urlopen = original_urlopen

        self.assertEqual("resend-message-id", message_id)
        self.assertEqual("https://api.resend.com/emails", captured["url"])
        self.assertEqual(worker.REPORT_READY_RESEND_USER_AGENT, captured["headers"]["User-agent"])
        self.assertEqual("report-package-ready-idempotency-key", captured["headers"]["Idempotency-key"])
        self.assertEqual(["recipient@example.test"], captured["payload"]["to"])
        self.assertIn("https://reports.example.test/reports?", captured["payload"]["text"])
        self.assertIn("Open Reports Portal:", captured["payload"]["text"])
        self.assertIn('href="https://reports.example.test/reports?', captured["payload"]["html"])
        self.assertIn("Open Reports Portal</a>", captured["payload"]["html"])
        self.assertIn('style="display:inline-block;background:#1C2742;', captured["payload"]["html"])
        self.assertIn(worker.REPORT_READY_EMAIL_LOGO_URL, captured["payload"]["html"])
        self.assertIn('alt="ScoutClear"', captured["payload"]["html"])
        self.assertIn("Sep 7, 2026 at 6:14 PM ET", captured["payload"]["html"])
        self.assertNotIn("UTC", captured["payload"]["html"])

    def test_resend_full_documentation_email_copy_stays_report_ready(self) -> None:
        captured: dict[str, Any] = {}

        class FakeResponse:
            def __enter__(self) -> "FakeResponse":
                return self

            def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
                return None

            def read(self) -> bytes:
                return b'{"id":"resend-message-id"}'

        def fake_urlopen(request: Any, timeout: int = 0) -> FakeResponse:
            captured["payload"] = json.loads(request.data.decode("utf-8"))
            return FakeResponse()

        original_urlopen = worker.urllib.request.urlopen
        worker.urllib.request.urlopen = fake_urlopen
        try:
            client = worker.ResendEmailClient(
                api_key="test-api-key",
                from_email="reports@example.test",
                portal_base_url="https://reports.example.test",
            )
            client.send(
                {"email": "recipient@example.test"},
                {
                    "property_name": "Test New Property",
                    "property_address": "123 Portal Way",
                    "session_datetime": "Sep 7, 2026 at 6:14 PM ET",
                },
                package(),
                "report-package-ready-idempotency-key",
            )
        finally:
            worker.urllib.request.urlopen = original_urlopen

        self.assertEqual("New Scout report ready: Test New Property", captured["payload"]["subject"])
        self.assertIn("New Scout report ready: Test New Property", captured["payload"]["text"])
        self.assertIn("Reports and photos are ready in the Scout Reports portal.", captured["payload"]["text"])
        self.assertIn("New Scout reports and photos are ready", captured["payload"]["html"])

    def test_resend_punchlist_visit_email_copy_says_punchlist_update(self) -> None:
        captured: dict[str, Any] = {}

        class FakeResponse:
            def __enter__(self) -> "FakeResponse":
                return self

            def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
                return None

            def read(self) -> bytes:
                return b'{"id":"resend-message-id"}'

        def fake_urlopen(request: Any, timeout: int = 0) -> FakeResponse:
            captured["payload"] = json.loads(request.data.decode("utf-8"))
            return FakeResponse()

        punchlist_package = package()
        punchlist_package["manifest"] = json.dumps({
            "sessionType": "punchlist_visit",
            "session_type": "punchlist_visit",
        })

        original_urlopen = worker.urllib.request.urlopen
        worker.urllib.request.urlopen = fake_urlopen
        try:
            client = worker.ResendEmailClient(
                api_key="test-api-key",
                from_email="reports@example.test",
                portal_base_url="https://reports.example.test",
            )
            client.send(
                {"email": "recipient@example.test"},
                {
                    "property_name": "Test New Property",
                    "property_address": "123 Portal Way",
                    "session_datetime": "Sep 7, 2026 at 6:14 PM ET",
                },
                punchlist_package,
                "punchlist-package-ready-idempotency-key",
            )
        finally:
            worker.urllib.request.urlopen = original_urlopen

        self.assertEqual("New Scout punchlist update ready: Test New Property", captured["payload"]["subject"])
        self.assertIn("New Scout punchlist update ready: Test New Property", captured["payload"]["text"])
        self.assertIn("Punchlist updates and photos are ready in the Scout Reports portal.", captured["payload"]["text"])
        self.assertIn("New Scout punchlist updates and photos are ready", captured["payload"]["html"])
        self.assertNotIn("New Scout report ready", captured["payload"]["text"])
        self.assertNotIn("Reports and photos are ready", captured["payload"]["text"])


if __name__ == "__main__":
    unittest.main()
