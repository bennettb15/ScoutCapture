"""Org logo lookup must never mix organizations or block report generation."""
from __future__ import annotations

import importlib.util
import io
import pathlib
import tempfile
import unittest
from contextlib import redirect_stderr


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "report_branding_worker", ROOT / "web-contract/report-production/report_worker_cli.py"
)
worker = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(worker)

ORG_ID = "11111111-1111-4111-8111-111111111111"
LOGO_PATH = f"orgs/{ORG_ID}/logos/33333333-3333-4333-8333-333333333333.png"
PNG = b"\x89PNG\r\n\x1a\n" + b"sample"


class FakeClient:
    def __init__(self, rows, image=PNG):
        self.rows = rows
        self.image = image
        self.downloaded = False

    def select(self, table, query):
        assert table == "org_report_branding"
        assert query["org_id"] == f"eq.{ORG_ID}"
        return self.rows

    def download_object(self, bucket, path):
        assert bucket == worker.BRANDING_BUCKET
        assert path == LOGO_PATH
        self.downloaded = True
        return self.image


class ReportBrandingTest(unittest.TestCase):
    def test_missing_logo_uses_scout(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assertIsNone(worker.load_org_report_logo(FakeClient([]), ORG_ID, pathlib.Path(temporary)))

    def test_scoped_logo_is_downloaded(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = FakeClient([{"logo_path": LOGO_PATH}])
            result = worker.load_org_report_logo(client, ORG_ID, pathlib.Path(temporary))
            self.assertTrue(client.downloaded)
            self.assertEqual(result.read_bytes(), PNG)

    def test_cross_org_logo_is_rejected_before_download(self):
        with tempfile.TemporaryDirectory() as temporary, redirect_stderr(io.StringIO()):
            client = FakeClient([{"logo_path": "orgs/other/logos/logo.png"}])
            self.assertIsNone(worker.load_org_report_logo(client, ORG_ID, pathlib.Path(temporary)))
            self.assertFalse(client.downloaded)


if __name__ == "__main__":
    unittest.main()
