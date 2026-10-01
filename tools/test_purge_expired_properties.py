import datetime as dt
import unittest
from unittest.mock import Mock

import purge_expired_properties as retention


class FakeClient:
    def __init__(self, shot_path="sessions/s1/shots/a/photo.heic"):
        self.shot_path = shot_path

    def rows(self, table, **filters):
        if table == "sessions":
            return [{"id": "s1"}]
        if table == "shots":
            return [{"storage_bucket": retention.ORIGINALS,
                     "storage_path": self.shot_path,
                     "session_id": "s1", "upload_state": "uploaded"}]
        if table == "session_snapshots":
            return [{"payload_storage_bucket": retention.SNAPSHOTS,
                     "payload_storage_path": "orgs/o/properties/p/sessions/s1/snapshots/a.json"}]
        return []

    def list_files(self, bucket, folder):
        if bucket == retention.DELIVERABLES:
            return ["orgs/o/properties/p/sessions/s1/previews/a.jpg"]
        return []


class RetentionTests(unittest.TestCase):
    def test_only_expired_non_archived_deleted_property_is_eligible(self):
        now = dt.datetime(2026, 10, 1, tzinfo=dt.timezone.utc)
        old = {"deleted_at": "2026-08-19T00:00:00Z", "is_archived": False}
        self.assertTrue(retention.expired_non_archived(old, now))
        self.assertFalse(retention.expired_non_archived({**old, "is_archived": True}, now))
        self.assertFalse(retention.expired_non_archived({**old, "deleted_at": None}, now))
        self.assertFalse(retention.expired_non_archived({**old, "deleted_at": "2026-09-29T00:00:00Z"}, now))

    def test_manifest_covers_recorded_media_and_unrecorded_previews(self):
        manifest = retention.media_manifest(FakeClient(), {"id": "p", "org_id": "o"})
        self.assertEqual(manifest[retention.ORIGINALS], ["sessions/s1/shots/a/photo.heic"])
        self.assertEqual(manifest[retention.SNAPSHOTS], ["orgs/o/properties/p/sessions/s1/snapshots/a.json"])
        self.assertEqual(manifest[retention.DELIVERABLES], ["orgs/o/properties/p/sessions/s1/previews/a.jpg"])

    def test_legacy_pathless_uploaded_shot_uses_recursive_session_listing_only_when_scoped(self):
        client = FakeClient(None)
        original_list_files = client.list_files

        def listed(bucket, folder):
            if bucket == retention.ORIGINALS and folder == "sessions/s1":
                return ["sessions/s1/shots/legacy/photo.heic"]
            return original_list_files(bucket, folder)

        client.list_files = listed
        with self.assertRaisesRegex(RuntimeError, "lacks a Storage path"):
            retention.media_manifest(client, {"id": "p", "org_id": "o"})
        manifest = retention.media_manifest(
            client, {"id": "p", "org_id": "o"}, allow_legacy_pathless_shots=True)
        self.assertEqual(manifest[retention.ORIGINALS],
                         ["sessions/s1/shots/legacy/photo.heic"])

    def test_refuses_media_outside_property(self):
        with self.assertRaisesRegex(RuntimeError, "outside its property sessions"):
            retention.media_manifest(FakeClient("sessions/other/shots/a/photo.heic"),
                                     {"id": "p", "org_id": "o"})

    def test_scoped_legacy_path_can_belong_to_another_session_of_same_property(self):
        client = FakeClient("sessions/s2/shots/a/photo.heic")
        original_rows = client.rows

        def rows(table, **filters):
            if table == "sessions":
                return [{"id": "s1"}, {"id": "s2"}]
            return original_rows(table, **filters)

        client.rows = rows
        with self.assertRaisesRegex(RuntimeError, "outside its property sessions"):
            retention.media_manifest(client, {"id": "p", "org_id": "o"})
        manifest = retention.media_manifest(client, {"id": "p", "org_id": "o"},
            allow_legacy_session_paths=True)
        self.assertEqual(manifest[retention.ORIGINALS],
                         ["sessions/s2/shots/a/photo.heic"])
        with self.assertRaisesRegex(RuntimeError, "outside its property sessions"):
            retention.media_manifest(FakeClient("sessions/other/shots/a/photo.heic"),
                {"id": "p", "org_id": "o"}, allow_legacy_session_paths=True)

    def test_manifest_distinguishes_unexpected_shot_bucket(self):
        client = FakeClient()
        original_rows = client.rows

        def rows(table, **filters):
            result = original_rows(table, **filters)
            if table == "shots":
                result[0]["storage_bucket"] = "other-bucket"
            return result

        client.rows = rows
        with self.assertRaisesRegex(RuntimeError, "unexpected Storage bucket"):
            retention.media_manifest(client, {"id": "p", "org_id": "o"})

    def test_storage_listing_descends_folders(self):
        client = retention.Client.__new__(retention.Client)
        client.request = Mock(side_effect=[
            [{"name": "child", "id": None}],
            [{"name": "photo.heic", "id": "object"}],
        ])
        self.assertEqual(client.list_files(retention.ORIGINALS, "sessions/s1"),
                         ["sessions/s1/child/photo.heic"])

    def test_storage_delete_batches_at_api_limit(self):
        client = retention.Client.__new__(retention.Client)
        client.request = Mock(return_value=[])
        client.remove_files(retention.ORIGINALS, [f"p/{i}" for i in range(1001)])
        self.assertEqual(client.request.call_count, 2)
        self.assertEqual(len(client.request.call_args_list[0].args[2]["prefixes"]), 1000)
        self.assertEqual(len(client.request.call_args_list[1].args[2]["prefixes"]), 1)


if __name__ == "__main__":
    unittest.main()
