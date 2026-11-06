import importlib.util
from pathlib import Path
import unittest

WORKER_PATH = Path(__file__).resolve().parents[1] / 'report-production/report_worker_cli.py'
spec = importlib.util.spec_from_file_location('report_worker_cli_org_test', WORKER_PATH)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class OrganizationAttributionTests(unittest.TestCase):
    def test_current_scoped_name_takes_precedence_over_capture_name(self):
        class Client:
            def select(self, table, query):
                self_query = query
                assert table == 'orgs'
                assert self_query['id'] == 'eq.org-1'
                return [{'name': 'Current Example Group'}]
        self.assertEqual(worker.generating_organization_name(Client(), 'org-1', 'Old Capture Name'),
                         'Current Example Group')

    def test_capture_name_is_used_when_the_current_name_is_unavailable(self):
        class Client:
            def select(self, table, query):
                return []
        self.assertEqual(worker.generating_organization_name(Client(), 'org-1', 'Capture Group'),
                         'Capture Group')
        with self.assertRaises(worker.WorkerError):
            worker.generating_organization_name(Client(), 'org-1')


if __name__ == '__main__':
    unittest.main()
