import datetime as dt
import json
import unittest
from io import BytesIO
from urllib.error import HTTPError

import purge_approved_test_org as cleanup


class FakeClient:
    def __init__(self, rows):
        self.properties = rows

    def rows(self, table, **filters):
        if table != "properties":
            raise AssertionError("Unexpected table")
        row = self.properties.get(filters["id"][3:])
        return [row] if row else []


class ApprovedTestOrgTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(cleanup.MANIFEST.read_text())

    def test_manifest_is_exact_and_disjoint(self):
        self.assertEqual(len(self.manifest["keep_property_ids"]), 5)
        self.assertEqual(len(self.manifest["purge"]), 53)
        ids = {item["id"] for item in self.manifest["purge"]}
        self.assertFalse(ids.intersection(self.manifest["keep_property_ids"]))

    def test_csv_and_api_utc_timestamps_match(self):
        csv_time = "2026-06-15 13:07:39.91279+00"
        api_time = "2026-06-15T13:07:39.912790+00:00"
        self.assertEqual(cleanup.utc_timestamp(csv_time), cleanup.utc_timestamp(api_time))
        self.assertEqual(cleanup.utc_timestamp(api_time).tzinfo, dt.timezone.utc)

    def test_protected_property_must_stay_active(self):
        property_id = self.manifest["keep_property_ids"][0]
        manifest = {"org_id": self.manifest["org_id"], "keep_property_ids": [property_id]}
        active = {"id": property_id, "org_id": manifest["org_id"],
                  "is_archived": False, "deleted_at": None}
        cleanup.verify_keep_set(FakeClient({property_id: active}), manifest)
        with self.assertRaisesRegex(RuntimeError, "protected"):
            cleanup.verify_keep_set(FakeClient({property_id: {**active, "deleted_at": "2026-10-01T00:00:00Z"}}), manifest)
        with self.assertRaisesRegex(RuntimeError, "protected"):
            cleanup.verify_keep_set(FakeClient({property_id: {**active, "is_archived": True}}), manifest)

    def test_rpc_reports_constraint_without_row_details(self):
        class FailingClient:
            def request(self, *_args, **_kwargs):
                payload = json.dumps({"code": "23503", "message":
                    'update or delete violates foreign key constraint "example_row_fkey"',
                    "details": "private property data"}).encode()
                raise HTTPError("https://example.test", 409, "Conflict", {}, BytesIO(payload))

        with self.assertRaisesRegex(RuntimeError, "SQLSTATE 23503; constraint example_row_fkey") as error:
            cleanup.rpc(FailingClient(), "private-id", False)
        self.assertNotIn("private property data", str(error.exception))
        self.assertNotIn("private-id", str(error.exception))

    def test_candidate_rejects_changed_deletion(self):
        candidate = self.manifest["purge"][0]
        row = {"id": candidate["id"], "org_id": self.manifest["org_id"],
               "is_archived": False, "deleted_at": candidate["deleted_at"]}
        self.assertEqual(cleanup.verify_candidate(FakeClient({candidate["id"]: row}),
                                                  self.manifest, candidate), row)
        with self.assertRaisesRegex(RuntimeError, "timestamp changed"):
            cleanup.verify_candidate(FakeClient({candidate["id"]: {**row, "deleted_at": "2026-10-01T00:00:00Z"}}),
                                     self.manifest, candidate)
        with self.assertRaisesRegex(RuntimeError, "archive state"):
            cleanup.verify_candidate(FakeClient({candidate["id"]: {**row, "is_archived": True}}),
                                     self.manifest, candidate)


if __name__ == "__main__":
    unittest.main()
