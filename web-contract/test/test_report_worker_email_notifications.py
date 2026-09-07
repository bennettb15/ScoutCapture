#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import pathlib
import unittest
from typing import Any


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
        self.tables: dict[str, list[dict[str, Any]]] = {
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
            "report_packages": [],
            worker.REPORT_READY_NOTIFICATION_TABLE: [],
        }

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

    def select(self, table: str, query: dict[str, str]) -> list[dict[str, Any]]:
        rows = [dict(row) for row in self.tables.get(table, [])]
        for key, value in query.items():
            if key in {"select", "limit", "order"}:
                continue
            if value.startswith("eq."):
                expected = value[3:]
                rows = [row for row in rows if str(row.get(key)) == expected]
            elif value.startswith("in.(") and value.endswith(")"):
                expected_values = set(value[4:-1].split(","))
                rows = [row for row in rows if str(row.get(key)) in expected_values]
            elif value == "is.null":
                rows = [row for row in rows if row.get(key) is None]
            else:
                raise AssertionError(f"Unsupported fake query: {key}={value}")
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
            matches = True
            for key, value in query.items():
                if not value.startswith("eq.") or str(existing.get(key)) != value[3:]:
                    matches = False
                    break
            if matches:
                existing.update(row)
                patched.append(dict(existing))
        return patched


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
                "property_name": "Test New Property",
                "property_address": "123 Portal Way, Austin, TX",
                "ended_at_utc": "2026-09-07T14:30:00Z",
            }
        }
    }


class ReportWorkerEmailNotificationTests(unittest.TestCase):
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
                    "session_datetime": "Sep 07, 2026 at 22:14 UTC",
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


if __name__ == "__main__":
    unittest.main()
