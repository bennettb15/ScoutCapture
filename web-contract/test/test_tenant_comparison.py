import importlib.util
import datetime as dt
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('tenant_comparison', ROOT/'report-production/tenant_comparison.py')
tenant = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tenant)


def photo(shot, issue=None, guided=None, angle=2):
    return dict(shot_id=shot, issue_id=issue, guided_row_id=guided, building='B1', elevation='North', detail_type='Overview', angle_index=angle)


class TenantComparisonTests(unittest.TestCase):
    def test_same_issue_matches_across_sessions_and_different_locations(self):
        old = photo('old', 'issue-1')
        new = photo('new', 'issue-1', angle=5)
        self.assertEqual(tenant.pair_entries([old], [new]), [(old, new, 'issue_id')])

    def test_tenant_cover_uses_the_same_first_overview_rule(self):
        renderer = tenant.load_renderer(ROOT.parent)
        detail = dict(shot_id='detail',session_id='session',detail_type='Door',captured_at_utc='2026-11-05T10:00:00Z')
        overview = dict(shot_id='overview',session_id='session',detail_type='Overview',captured_at_utc='2026-11-05T10:01:00Z')
        validation = dict(session_id='session',source_snapshot_id='snapshot',inputs=dict(session=dict(session_id='session'),
            ordered_shots=[detail,overview],property_report_entries=[dict(kind='photo',shot_id='detail'),dict(kind='photo',shot_id='overview')]))
        media = {'items':[dict(role='current',shot_id=s['shot_id'],temporary_prepared_path=f"/{s['shot_id']}.jpg") for s in [detail,overview]]}
        plan = tenant.build_plan(renderer,validation,validation,media,media,{})
        self.assertEqual(plan['pages'][0]['cover_shot_id'],'overview')

    def test_distinct_issues_at_same_location_are_not_matched(self):
        pairs = tenant.pair_entries([photo('a', 'issue-a')], [photo('b', 'issue-b')])
        self.assertEqual(len(pairs), 2)
        self.assertIsNone(pairs[0][1])
        self.assertIsNone(pairs[1][0])

    def test_guided_identity_and_unchanged_photo(self):
        old, new = photo('a', guided='view-1'), photo('b', guided='view-1')
        self.assertEqual(tenant.pair_entries([old], [new])[0][2], 'guided_row_id')
        self.assertEqual(tenant.pair_entries([old], [old])[0][2], 'shot_id')

    def test_legacy_unique_view_fallback_and_ambiguous_view(self):
        self.assertEqual(tenant.pair_entries([photo('a')], [photo('b')])[0][2], 'documented_view')
        pairs = tenant.pair_entries([photo('a'), photo('b')], [photo('c')])
        self.assertTrue(all(not (left and right) for left, right, _ in pairs))

    def test_scope_and_version_order(self):
        row = dict(org_id='org', property_id='prop')
        before = dict(id='b', **row, session_completed_at='2026-10-01')
        after = dict(id='a', **row, session_completed_at='2026-10-02')
        tenant.validate_packages(row, before, after)
        for key in ('org_id', 'property_id'):
            with self.assertRaises(ValueError):
                tenant.validate_packages(row, before, {**after, key:'other'})
        with self.assertRaises(ValueError):
            tenant.validate_packages(row, after, before)

    def test_expired_outputs_are_deleted_without_touching_package_pdfs(self):
        row = dict(id='request', org_id='org', property_id='prop')
        row['storage_path'] = tenant.expected_path(row)
        calls = []
        class Client:
            def select(self, table, query):
                return [row] if 'expires_at' in query and 'status' not in query else []
            def delete_object(self, bucket, path): calls.append((bucket,path))
            def delete_rows(self, table, query): calls.append((table,query))
            def patch(self, *args): return []
        tenant.drain(SimpleNamespace(), Client(), ROOT.parent, SimpleNamespace(safe_iso_now=lambda: '2026-10-02'))
        self.assertEqual(calls[0], (tenant.BUCKET, row['storage_path']))
        self.assertEqual(calls[1][0], tenant.TABLE)

    def test_cross_scope_job_fails_without_upload_and_cleans_local_files(self):
        row = dict(id='request', org_id='org', property_id='prop', before_package_id='b', after_package_id='a')
        updates = []
        class Client:
            def select(self, *args): return [row]
            def patch(self, table, query, value): updates.append(value); return [row]
            def upload_object(self, *args, **kwargs): raise AssertionError('must not upload')
        worker = SimpleNamespace(safe_iso_now=lambda:'2026-10-02', select_ready_package=lambda client,id:dict(id=id,org_id='other',property_id='prop'))
        with tempfile.TemporaryDirectory() as folder:
            tenant.process_request(SimpleNamespace(output_dir=folder), Client(), ROOT.parent, row['id'], worker)
            self.assertEqual(updates[-1]['status'], 'failed')
            self.assertFalse((Path(folder)/'tenant-comparisons'/row['id']).exists())

    def test_successful_job_uses_pinned_snapshots_and_only_writes_temporary_artifacts(self):
        row = dict(id='request', org_id='org', property_id='prop', before_package_id='b', after_package_id='a')
        updates, uploads, commands = [], [], []
        packages = {key: dict(id=key, org_id='org', property_id='prop', session_id=key,
                             snapshot_id=f'snapshot-{key}', session_completed_at=f'2026-10-0{i+1}')
                    for i, key in enumerate(('b', 'a'))}
        class Client:
            def select(self, table, query):
                if table == tenant.TABLE: return [row]
                if table == 'shots':
                    sid = query['id'][4:-1]
                    return [dict(id=sid,session_id=sid,org_id='org',property_id='prop',storage_bucket='scoutcapture-originals',storage_path=f'sessions/{sid}/shots/{sid}/sample.jpg')]
                if table == 'sessions': return [{'id':query['id'][4:-1]}]
                return [{'id':'prop'}]
            def patch(self, table, query, value):
                self.assert_table(table)
                updates.append(value)
                return [row]
            def assert_table(self, table):
                if table != tenant.TABLE: raise AssertionError('must not modify report packages')
            def upload_object(self, bucket, path, file, mime, upsert):
                uploads.append((bucket,path,mime,upsert,file.read_bytes()))
        def write_json(path, value, pretty):
            path.write_text(json.dumps(value))
        def run_step(command, repo, env):
            commands.append(command)
            if '--session-id' in command:
                sid = command[command.index('--session-id')+1]
                value = dict(session_id=sid, source_snapshot_id=f'snapshot-{sid}', session_type='full_documentation' if sid == 'b' else 'punchlist_visit',
                    media={'missing_count':0}, reports={'property_report':{'applicable':True}},
                    inputs={'session':{}, 'ordered_shots':[{'shot_id':sid, 'session_id':sid, 'media':{'bucket':'scoutcapture-originals','path':f'sessions/{sid}/shots/{sid}/sample.jpg'}}], 'property_report_entries':[{'kind':'photo','shot_id':sid}]})
                write_json(Path(command[command.index('--output')+1]),value,False)
            else:
                media = Path(command[command.index('--output-dir')+1]);media.mkdir()
                write_json(media/'prepared_report_media.json', {'items':[]},False)
        worker = SimpleNamespace(safe_iso_now=lambda:'2026-10-03', select_ready_package=lambda client,id:packages[id],
            snapshot_metadata=lambda client,id:dict(org_id='org',property_id='prop'), run_step=run_step,
            read_json=lambda path:json.loads(path.read_text()), write_json=write_json,
            load_org_report_logo=lambda client, org_id, output_dir: None, PACKAGED_LOGO_SVG='logo.svg',
            generating_organization_name=lambda client,org_id,fallback: 'Current Example Group')
        renderer = SimpleNamespace(logo_info=lambda *args:{}, render_pdf=lambda plan,path:path.write_bytes(b'%PDF-test'))
        with tempfile.TemporaryDirectory() as folder, patch.object(tenant,'load_renderer',return_value=renderer), patch.object(tenant,'build_plan',return_value={}):
            started = dt.datetime.now(dt.timezone.utc)
            tenant.process_request(SimpleNamespace(output_dir=folder),Client(),ROOT.parent,row['id'],worker)
            self.assertEqual(updates[-1]['status'],'ready')
            self.assertEqual([u['progress_step'] for u in updates], ['validating','preparing_photos','rendering','uploading','ready'])
            expiry = dt.datetime.fromisoformat(updates[-1]['expires_at'])
            self.assertGreaterEqual(expiry, started + dt.timedelta(hours=24))
            self.assertLess(expiry, dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=24, seconds=1))
            self.assertEqual(uploads,[(tenant.BUCKET,tenant.expected_path(row),'application/pdf',False,b'%PDF-test')])
            self.assertFalse((Path(folder)/'tenant-comparisons'/row['id']).exists())
        inputs = [command for command in commands if '--session-id' in command]
        self.assertEqual(sorted(command[command.index('--snapshot-id')+1] for command in inputs),['snapshot-a','snapshot-b'])
        self.assertTrue(all('--snapshot-history-only' in command for command in inputs))

    def test_source_photo_must_match_canonical_property_session_and_storage_path(self):
        row = dict(org_id='org',property_id='prop')
        photo = dict(id='photo',session_id='session',org_id='org',property_id='prop',storage_bucket='scoutcapture-originals',storage_path='sessions/session/shots/photo/image.jpg')
        shot = dict(shot_id='photo',session_id='session',media={'bucket':photo['storage_bucket'],'path':photo['storage_path']})
        def client_for(value):
            return SimpleNamespace(select=lambda table,query:[value] if table == 'shots' else [{'id':'session'}])
        tenant.validate_photo_scope(client_for(photo),row,[shot])
        for changed in ({'org_id':'other'},{'property_id':'other'},{'session_id':'other'},
                        {'storage_path':'sessions/other/shots/photo/image.jpg'},{'storage_bucket':'other'}):
            with self.assertRaises(ValueError):
                tenant.validate_photo_scope(client_for({**photo,**changed}),row,[shot])


if __name__ == '__main__':
    unittest.main()
