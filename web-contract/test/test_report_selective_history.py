import importlib.util
import json
import tempfile
from types import SimpleNamespace
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / 'report-input' / 'report_input_phase1.py'
spec = importlib.util.spec_from_file_location('report_input_phase1', MODULE_PATH)
report_input = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = report_input
spec.loader.exec_module(report_input)
RENDERER_PATH = ROOT / 'report-renderer' / 'report_renderer_phase2b.py'
renderer_spec = importlib.util.spec_from_file_location('report_renderer_phase2b', RENDERER_PATH)
report_renderer = importlib.util.module_from_spec(renderer_spec)
sys.modules[renderer_spec.name] = report_renderer
renderer_spec.loader.exec_module(report_renderer)

ORG = 'org-a'
PROPERTY = 'property-a'


def source(name, day, kind, shots, issues=None, guided=None, property_id=PROPERTY, org_id=ORG):
    sid = f'session-{name}'
    metadata = {
        'sessionID': sid, 'propertyID': property_id, 'orgID': org_id,
        'sessionType': kind, 'startedAt': f'2026-10-{day:02d}T10:00:00Z',
        'endedAt': f'2026-10-{day:02d}T11:00:00Z', 'shots': shots,
        'issues': issues or [], 'guidedShots': guided or [],
    }
    return {
        'row': {'id': f'snapshot-{name}', 'session_id': sid, 'org_id': org_id,
                'property_id': property_id, 'snapshot_kind': 'completed',
                'session_status': 'completed', 'is_sealed': True,
                'created_at': f'2026-10-{day:02d}T12:00:00Z'},
        'payload': {'rawSessionJSON': json.dumps(metadata)},
        'metadata': metadata, 'session_type': kind,
        'started': report_input.parse_date(metadata['startedAt']),
    }


def shot(i, name, day, guided=False, status='active', kind='captured'):
    return {'shotID': f'photo-{i}-{name}', 'issueID': f'issue-{i}',
            'sessionID': f'session-{name}', 'createdAt': f'2026-10-{day:02d}T10:30:00Z',
            'building': 'B1', 'elevation': 'North', 'detailType': 'Overview',
            'angleIndex': i, 'isGuided': guided, 'isFlagged': True,
            'issueStatus': status, 'captureKind': kind, 'priority': 'high',
            'originalFilename': f'{i}-{name}.jpg',
            'storagePath': f'sessions/session-{name}/shots/photo-{i}-{name}/{i}-{name}.jpg'}


def issue(i, status='active'):
    return {'issueID': f'issue-{i}', 'issueStatus': status,
            'currentReason': f'Observation {i}'}


class Storage:
    def exists(self, bucket, path):
        return bool(path)


class SelectiveHistoryTests(unittest.TestCase):
    def setUp(self):
        self.baseline = source('full', 1, 'full_documentation',
                               [shot(i, 'full', 1, guided=True) for i in range(8)],
                               [issue(i) for i in range(8)],
                               [{'id': f'guided-{i}'} for i in range(8)])
        self.visit1 = source('visit1', 2, 'punchlist_visit',
                             [shot(0, 'visit1', 2, kind='follow_up_capture')], [issue(0)])
        self.visit2 = source('visit2', 3, 'punchlist_visit',
                             [shot(1, 'visit2', 3, kind='follow_up_capture')], [issue(1)])

    def test_one_of_eight_replaces_only_updated_property_photo(self):
        result = report_input.compose_punchlist_history([self.baseline, self.visit1], Storage())
        self.assertEqual(len(result['punchlist_shots']), 8)
        self.assertEqual({s['shot_id'] for s in result['punchlist_shots']},
                         {'photo-0-visit1'} | {f'photo-{i}-full' for i in range(1, 8)})
        self.assertEqual(len(result['entries']), 8)
        self.assertEqual({e['shot_id'] for e in result['entries']},
                         {'photo-0-visit1'} | {f'photo-{i}-full' for i in range(1, 8)})
        self.assertNotIn('photo-0-full', [e['shot_id'] for e in result['entries']])
        self.assertEqual(result['baseline']['session_id'], 'session-full')
        self.assertEqual(result['comparisons'][0]['matching_rule'], 'same_issue_id')
        self.assertEqual(next(item['previous_shot_id'] for item in result['comparisons']
                              if item['issue_id'] == 'issue-0'), 'photo-0-full')

    def test_property_shows_only_latest_photo_and_uses_current_visit_time(self):
        self.visit1['metadata']['shots'][0]['createdAt'] = '2026-10-02T10:45:00Z'
        result = report_input.compose_punchlist_history([self.baseline, self.visit1], Storage())
        validation = {
            'session_id': 'session-visit1', 'session_type': 'punchlist_visit',
            'inputs': {'session': {'session_id': 'session-visit1',
                                   'started_at_utc': '2026-10-02T10:00:00Z',
                                   'ended_at_utc': '2026-10-02T11:00:00Z'},
                       'ordered_shots': result['shots'],
                       'punchlist_shots': result['punchlist_shots'],
                       'property_report_entries': result['entries']},
        }
        entries = report_renderer.property_entries(validation, report_renderer.media_lookup({}))
        self.assertEqual(len(entries), 8)
        self.assertEqual(sum(e['shot_id'] == 'photo-0-visit1' for e in entries), 1)
        self.assertNotIn('photo-0-full', [e['shot_id'] for e in entries])
        self.assertFalse(any('FOLLOW-UP PHOTO' in e['caption'] for e in entries))
        self.assertEqual(next(e['captured_at_utc'] for e in entries if e['shot_id'] == 'photo-0-visit1'),
                         '2026-10-02T10:45:00Z')
        self.assertEqual(next(e['captured_at_utc'] for e in entries if e['shot_id'] == 'photo-1-full'),
                         '2026-10-01T10:30:00Z')
        self.assertEqual(report_renderer.time_window(validation), '6:45 AM')
        priority = report_renderer.build_priority_plan(
            validation, report_renderer.media_lookup({}), '10/02/2026', {}, {})
        priority_shot_ids = [slot['entry']['shot_id'] for page in priority['pages']
                             for slot in page.get('slots', [])]
        self.assertIn('photo-0-visit1', priority_shot_ids)
        self.assertNotIn('photo-0-full', priority_shot_ids)
        self.assertEqual(len(priority_shot_ids), 8)

    def test_status_only_visit_time_does_not_claim_old_photo_time(self):
        result = report_input.compose_punchlist_history([self.baseline], Storage())
        validation = {
            'session_id': 'session-status', 'session_type': 'punchlist_visit',
            'inputs': {'session': {'session_id': 'session-status',
                                   'started_at_utc': '2026-10-02T10:00:00Z',
                                   'ended_at_utc': '2026-10-02T11:00:00Z'},
                       'ordered_shots': result['shots']},
        }
        self.assertEqual(report_renderer.time_window(validation), '6:00 AM to 7:00 AM')

    def test_multiple_visits_and_resolved_state(self):
        self.visit2['metadata']['issues'].append(issue(0, 'resolved'))
        self.visit2['payload']['rawSessionJSON'] = json.dumps(self.visit2['metadata'])
        result = report_input.compose_punchlist_history(
            [self.baseline, self.visit1, self.visit2], Storage())
        self.assertEqual(len(result['punchlist_shots']), 8)
        by_issue = {s['issue_id']: s for s in result['punchlist_shots']}
        self.assertEqual(by_issue['issue-0']['shot_id'], 'photo-0-visit1')
        self.assertTrue(by_issue['issue-0']['is_resolved_in_session'])
        self.assertEqual(by_issue['issue-0']['captured_at_utc'], '2026-10-02T10:30:00Z')
        self.assertEqual(by_issue['issue-1']['shot_id'], 'photo-1-visit2')
        self.assertEqual(by_issue['issue-2']['shot_id'], 'photo-2-full')
        self.assertEqual(by_issue['issue-2']['captured_at_utc'], '2026-10-01T10:30:00Z')

    def test_many_selective_visits_keep_the_original_baseline(self):
        visits = [source(f'visit-{i}', i + 2, 'punchlist_visit',
                         [shot(i, f'visit-{i}', i + 2, kind='follow_up_capture')],
                         [issue(i)]) for i in range(7)]
        result = report_input.compose_punchlist_history([self.baseline, *visits], Storage())
        self.assertEqual(len(result['punchlist_shots']), 8)
        self.assertEqual(result['baseline']['snapshot_id'], 'snapshot-full')
        self.assertEqual(result['punchlist_shots'][-1]['shot_id'], 'photo-6-visit-6')
        self.assertEqual(len(result['entries']), 8)
        self.assertEqual({e['shot_id'] for e in result['entries']},
                         {f'photo-{i}-visit-{i}' for i in range(7)} | {'photo-7-full'})

    def test_untyped_follow_up_is_not_a_full_baseline(self):
        metadata = dict(self.visit1['metadata'])
        metadata.pop('sessionType')
        self.assertEqual(report_input.normalized_session_type(metadata), 'punchlist_visit')

    def test_new_full_session_replaces_guided_baseline(self):
        full2 = source('full2', 4, 'full_documentation', [shot(0, 'full2', 4, guided=True)],
                       [issue(0)], [{'id': 'new-guided'}])
        visit3 = source('visit3', 5, 'punchlist_visit', [shot(0, 'visit3', 5)], [issue(0)])
        result = report_input.compose_punchlist_history(
            [self.baseline, self.visit1, full2, visit3], Storage())
        self.assertEqual(result['baseline']['session_id'], 'session-full2')
        self.assertEqual([e['shot_id'] for e in result['entries']],
                         ['photo-0-visit3'])

    def test_repeated_updates_replace_by_issue_identity(self):
        # Two different issues share a location; only the updated issue is replaced.
        self.baseline['metadata']['shots'][1]['angleIndex'] = 1
        self.baseline['metadata']['shots'][0]['angleIndex'] = 1
        repeat = source('repeat', 4, 'punchlist_visit',
                        [shot(0, 'repeat', 4, kind='follow_up_capture')], [issue(0)])
        result = report_input.compose_punchlist_history(
            [self.baseline, self.visit1, repeat], Storage())
        ids = [e['shot_id'] for e in result['entries']]
        self.assertEqual(len(ids), 8)
        self.assertIn('photo-0-repeat', ids)
        self.assertIn('photo-1-full', ids)
        self.assertNotIn('photo-0-full', ids)
        self.assertNotIn('photo-0-visit1', ids)
        previous = next(item for item in result['comparisons'] if item['issue_id'] == 'issue-0')
        self.assertEqual(previous['previous_shot_id'], 'photo-0-visit1')

    def test_new_issue_is_added_without_replacing_an_unrelated_guided_photo(self):
        new_issue = source('new', 4, 'punchlist_visit',
                           [shot(8, 'new', 4, kind='follow_up_capture')], [issue(8)])
        result = report_input.compose_punchlist_history([self.baseline, new_issue], Storage())
        self.assertEqual(len(result['entries']), 9)
        self.assertEqual({e['shot_id'] for e in result['entries']},
                         {f'photo-{i}-full' for i in range(8)} | {'photo-8-new'})

    def test_no_full_baseline_and_reference_does_not_replace_photo(self):
        reference = source('reference', 4, 'punchlist_visit',
                           [shot(0, 'reference', 4, kind='reference')], [issue(0)])
        result = report_input.compose_punchlist_history([self.visit1, reference], Storage())
        self.assertIsNone(result['baseline'])
        self.assertEqual(result['entries'], [])
        self.assertEqual(result['punchlist_shots'][0]['shot_id'], 'photo-0-visit1')

    def test_validation_composes_a_complete_package(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'row.json').write_text(json.dumps(self.visit2['row']))
            (root / 'payload.json').write_text(json.dumps(self.visit2['payload']))
            (root / 'history.json').write_text(json.dumps([
                {'row': source['row'], 'payload': source['payload']}
                for source in (self.baseline, self.visit1, self.visit2)]))
            objects = [{'bucket': 'scoutcapture-originals', 'path': shot['storagePath']}
                       for source in (self.baseline, self.visit1, self.visit2)
                       for shot in source['metadata']['shots']]
            (root / 'storage.json').write_text(json.dumps({'objects': objects}))
            args = SimpleNamespace(snapshot_row_fixture=str(root / 'row.json'),
                snapshot_payload_fixture=str(root / 'payload.json'),
                history_fixture=str(root / 'history.json'),
                storage_fixture=str(root / 'storage.json'), canonical_fixture=None,
                include_runtime=False, session_id=None, snapshot_id=None)
            validation = report_input.build_validation(args)
        self.assertTrue(validation['renderable_remotely'])
        self.assertTrue(validation['reports']['property_report']['applicable'])
        self.assertEqual(validation['reports']['priority_report']['flagged_shot_count'], 8)
        self.assertEqual(validation['reports']['flagged_comparison']['comparison_count'], 8)
        self.assertEqual(validation['source_provenance']['guided_baseline']['snapshot_id'], 'snapshot-full')
        self.assertEqual(validation['inputs']['ordered_shots'][0]['shot_id'], 'photo-0-full')

    def test_validation_without_full_baseline_skips_property_report(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'row.json').write_text(json.dumps(self.visit2['row']))
            (root / 'payload.json').write_text(json.dumps(self.visit2['payload']))
            (root / 'history.json').write_text(json.dumps([
                {'row': source['row'], 'payload': source['payload']}
                for source in (self.visit1, self.visit2)]))
            objects = [{'bucket': 'scoutcapture-originals', 'path': shot['storagePath']}
                       for source in (self.visit1, self.visit2)
                       for shot in source['metadata']['shots']]
            (root / 'storage.json').write_text(json.dumps({'objects': objects}))
            args = SimpleNamespace(snapshot_row_fixture=str(root / 'row.json'),
                snapshot_payload_fixture=str(root / 'payload.json'),
                history_fixture=str(root / 'history.json'),
                storage_fixture=str(root / 'storage.json'), canonical_fixture=None,
                include_runtime=False, session_id=None, snapshot_id=None)
            validation = report_input.build_validation(args)
        self.assertFalse(validation['reports']['property_report']['applicable'])
        self.assertEqual(validation['inputs']['property_report_entries'], [])

    def test_portal_activity_status_and_priority(self):
        composition = report_input.compose_punchlist_history([self.baseline, self.visit1], Storage())
        report_input.apply_operational_overlays(composition, {
            'issue-0': {'activity_status': 'resolved', 'activity_priority': 'critical'}})
        by_issue = {shot['issue_id']: shot for shot in composition['punchlist_shots']}
        self.assertTrue(by_issue['issue-0']['is_resolved_in_session'])
        self.assertEqual(by_issue['issue-0']['normalized_priority'], 'critical')
        self.assertEqual(by_issue['issue-0']['captured_at_utc'], '2026-10-02T10:30:00Z')

    def test_portal_activity_scope_cannot_mix_organizations(self):
        class Client:
            def select_rows(self, table, query):
                if table == 'observations':
                    return [{'id': 'issue-0', 'org_id': ORG, 'property_id': PROPERTY,
                             'status': 'active', 'priority': 'high'}]
                return [{'id': 'activity-other-org', 'observation_id': 'issue-0',
                         'org_id': 'org-b', 'property_id': PROPERTY,
                         'activity_type': 'status_changed', 'to_value': 'resolved'}]
        with self.assertRaises(report_input.Phase1Error):
            report_input.operational_issue_overlays(Client(), self.visit1['row'], ['issue-0'])

    def test_scope_rejects_cross_property_and_organization(self):
        class Args:
            history_fixture = None
        current = self.visit1
        for wrong in (source('other-property', 1, 'full_documentation', [],
                             property_id='property-b'),
                      source('other-org', 1, 'full_documentation', [], org_id='org-b')):
            class Client:
                def select_rows(self, *args):
                    return [wrong['row']]
                def download_storage_json(self, *args):
                    return wrong['payload']
            with self.assertRaises(report_input.Phase1Error):
                report_input.scoped_snapshot_history(Args(), Client(), current['row'],
                                                     current['payload'], current['metadata'])


if __name__ == '__main__':
    unittest.main()
