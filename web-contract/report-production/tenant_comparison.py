"""On-demand tenant PDFs using the existing report input, media, and renderer."""
from __future__ import annotations
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys

TABLE = 'on_demand_report_requests'
BUCKET = 'scoutcapture-on-demand'


def load_renderer(repo):
    name = 'tenant_shared_renderer'
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, repo / 'web-contract/report-renderer/report_renderer_phase2b.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def pair_entries(before, after):
    """Match stable identities first; unique view fallback never merges distinct issues."""
    pairs = []
    remaining = list(after)
    for old in before:
        match = None
        basis = 'unmatched'
        for key in ('shot_id', 'guided_row_id', 'issue_id'):
            value = str(old.get(key) or '').lower()
            if value and sum(str(item.get(key) or '').lower() == value for item in before) != 1:
                continue
            candidates = [item for item in remaining if value and str(item.get(key) or '').lower() == value]
            if len(candidates) == 1:
                match, basis = candidates[0], key
                break
        if match is None:
            view = lambda item: tuple(str(item.get(k) or '').strip().lower() for k in ('building','elevation','detail_type','angle_index'))
            candidates = [item for item in remaining if view(item) == view(old) and
                          not (old.get('issue_id') and item.get('issue_id') and old['issue_id'].lower() != item['issue_id'].lower()) and
                          not (old.get('guided_row_id') and item.get('guided_row_id') and old['guided_row_id'].lower() != item['guided_row_id'].lower())]
            if len(candidates) == 1 and sum(view(item) == view(old) for item in before) == 1:
                match, basis = candidates[0], 'documented_view'
        if match is not None:
            remaining.remove(match)
        pairs.append((old, match, basis))
    return pairs + [(None, item, 'unmatched') for item in remaining]


def build_plan(renderer, before, after, before_media, after_media, logo):
    old = renderer.property_entries(before, renderer.media_lookup(before_media))
    new = renderer.property_entries(after, renderer.media_lookup(after_media))
    pairs = pair_entries(old, new)
    if not pairs:
        raise ValueError('No documented views are available for comparison.')
    pages = [{'number': 1, 'kind': 'cover', 'title': 'Tenant Comparison Report', 'cover_media_path': next((e.get('media_path') for e in new if e.get('media_path')), None)}]
    for number, (left, right, basis) in enumerate(pairs, 2):
        pages.append({'number': number, 'kind': 'tenant_comparison', 'before': renderer.compact_entry(left or {}),
                      'after': renderer.compact_entry(right or {}), 'matching_basis': basis,
                      'same_photo': bool(left and right and left.get('shot_id') == right.get('shot_id'))})
    plan = renderer.make_plan('property', after['inputs']['session'], after, renderer.media_lookup(after_media),
                              renderer.short_date(dt.datetime.now(dt.timezone.utc).isoformat()), pages, logo, {})
    plan['report_type'] = 'tenant_comparison'
    plan['comparison_versions'] = {'before_session_id': before['session_id'], 'after_session_id': after['session_id'],
        'before_snapshot_id': before['source_snapshot_id'], 'after_snapshot_id': after['source_snapshot_id'],
        'before_date': before['inputs']['session'].get('ended_at_utc'), 'after_date': after['inputs']['session'].get('ended_at_utc')}
    return plan


def expected_path(row):
    folder = 'punchlists' if row.get('kind') == 'punchlist_all' else 'tenant-comparisons'
    return f"orgs/{row['org_id']}/properties/{row['property_id']}/{folder}/{row['id']}.pdf"


def validate_packages(row, before, after):
    for package in (before, after):
        if any(str(package.get(k) or '').lower() != str(row[k]).lower() for k in ('org_id', 'property_id')):
            raise ValueError('Cross-property or cross-organization comparison rejected.')
    if before['id'] == after['id'] or str(before.get('session_completed_at') or '') > str(after.get('session_completed_at') or ''):
        raise ValueError('Invalid comparison version order.')


def validate_photo_scope(client, row, shots):
    for offset in range(0, len(shots), 60):
        batch = shots[offset:offset + 60]
        ids = ','.join(shot['shot_id'] for shot in batch)
        photos = client.select('shots', {'select':'id,session_id,org_id,property_id,storage_bucket,storage_path',
            'id':f'in.({ids})', 'org_id':f'eq.{row["org_id"]}', 'deleted_at':'is.null', 'upload_state':'eq.uploaded'})
        sessions = client.select('sessions', {'select':'id', 'id':f'in.({",".join({p["session_id"] for p in photos})})',
            'org_id':f'eq.{row["org_id"]}', 'property_id':f'eq.{row["property_id"]}', 'deleted_at':'is.null'}) if photos else []
        allowed_sessions = {s['id'].lower() for s in sessions}
        by_id = {p['id'].lower():p for p in photos}
        for shot in batch:
            photo = by_id.get(shot['shot_id'].lower())
            media = shot.get('media') or {}
            path = (photo or {}).get('storage_path') or ''
            prefix = f"sessions/{(photo or {}).get('session_id')}/shots/{(photo or {}).get('id')}/"
            leaf = path[len(prefix):]
            if (not photo or photo.get('org_id') != row['org_id'] or
                (photo.get('property_id') and photo['property_id'] != row['property_id']) or
                photo['session_id'].lower() not in allowed_sessions or
                photo['session_id'].lower() != (shot.get('source_shot_session_id') or shot['session_id']).lower() or
                photo.get('storage_bucket') != 'scoutcapture-originals' or
                not path.lower().startswith(prefix.lower()) or not leaf or '/' in leaf or leaf in ('.','..') or
                photo.get('storage_bucket') != media.get('bucket') or path != media.get('path')):
                raise ValueError('Source photo scope mismatch.')


def process_request(args, client, repo, request_id, worker):
    rows = client.select(TABLE, {'select':'*', 'id': f'eq.{request_id}', 'kind':'eq.tenant_comparison', 'status':'eq.queued', 'expires_at':f'gt.{worker.safe_iso_now()}', 'limit':'1'})
    if not rows:
        return
    row = rows[0]
    claimed = client.patch(TABLE, {'id':f'eq.{row["id"]}', 'status':'eq.queued'}, {'status':'generating', 'locked_at':worker.safe_iso_now()})
    if not claimed:
        return
    root = Path(args.output_dir).resolve() / 'tenant-comparisons' / row['id']
    root.mkdir(parents=True, exist_ok=True)
    path = expected_path(row)
    uploaded = False
    try:
        before = worker.select_ready_package(client, row['before_package_id'])
        after = worker.select_ready_package(client, row['after_package_id'])
        validate_packages(row, before, after)
        properties = client.select('properties', {'select':'id', 'id':f'eq.{row["property_id"]}', 'org_id':f'eq.{row["org_id"]}', 'deleted_at':'is.null'})
        if not properties:
            raise ValueError('Property is unavailable.')
        validations, prepared = [], []
        for label, package in (('before',before), ('after',after)):
            folder = root / label
            folder.mkdir()
            validation_path = folder / 'validation.json'
            command = [sys.executable, str(repo/'web-contract/report-input/report_input_phase1.py'),
                '--session-id', package['session_id'], '--snapshot-id', package['snapshot_id'], '--snapshot-history-only', '--output', str(validation_path)]
            provenance = (package.get('manifest') or {}).get('source_provenance') or {}
            source_rows = []
            for source in provenance.get('source_snapshots') or []:
                snapshot = worker.snapshot_metadata(client, source['snapshot_id'])
                if any(str(snapshot.get(k) or '').lower() != str(row[k]).lower() for k in ('org_id','property_id')):
                    raise ValueError('Cross-scope source provenance rejected.')
                payload = json.loads(client.download_object(snapshot['payload_storage_bucket'], snapshot['payload_storage_path']))
                source_rows.append({'row': snapshot, 'payload': payload})
            if source_rows:
                history_path = folder/'history.json'
                worker.write_json(history_path, source_rows, False)
                command.extend(['--history-fixture', str(history_path)])
            worker.run_step(command, repo, dict(os.environ))
            validation = worker.read_json(validation_path)
            if validation['source_snapshot_id'] != package['snapshot_id'] or validation['session_id'] != package['session_id']:
                raise ValueError('Snapshot provenance mismatch.')
            snapshot = worker.snapshot_metadata(client, package['snapshot_id'])
            if any(str(snapshot.get(k) or '').lower() != str(row[k]).lower() for k in ('org_id','property_id')):
                raise ValueError('Snapshot scope mismatch.')
            if not validation.get('reports', {}).get('property_report', {}).get('applicable'):
                raise ValueError('This version has no full documentation baseline.')
            if label == 'before' and validation.get('session_type') != 'full_documentation':
                raise ValueError('The before version must be Full Documentation.')
            # Download only photos actually displayed in this Property Report.
            ids = {entry.get('shot_id') for entry in validation['inputs']['property_report_entries']}
            validation['inputs']['ordered_shots'] = [s for s in validation['inputs']['ordered_shots'] if s['shot_id'] in ids]
            if any(not item.get('exists') and item.get('shot_id') in ids for item in validation.get('media', {}).get('items', [])):
                raise ValueError('Source photos are unavailable.')
            validate_photo_scope(client, row, validation['inputs']['ordered_shots'])
            worker.write_json(validation_path, validation, False)
            media_dir = folder/'media'
            worker.run_step([sys.executable, str(repo/'web-contract/report-media/report_media_phase2a.py'),
                '--validation-json', str(validation_path), '--output-dir', str(media_dir)], repo, dict(os.environ))
            media = worker.read_json(media_dir/'prepared_report_media.json')
            if media.get('errors'):
                raise ValueError('Photo preparation failed.')
            validations.append(validation)
            prepared.append(media)
        renderer = load_renderer(repo)
        plan = build_plan(renderer, *validations, *prepared, renderer.logo_info(None, str(repo/worker.PACKAGED_LOGO_SVG)))
        filename = 'Tenant Comparison Report.pdf'
        pdf = root/filename
        renderer.render_pdf(plan, pdf)
        # Recheck live property/package scope before making the temporary output available.
        validate_packages(row, worker.select_ready_package(client, before['id']), worker.select_ready_package(client, after['id']))
        client.upload_object(BUCKET, path, pdf, 'application/pdf', upsert=False)
        uploaded = True
        expiry = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=1)).isoformat()
        client.patch(TABLE, {'id':f'eq.{row["id"]}', 'status':'eq.generating'}, {'status':'ready', 'storage_path':path, 'filename':filename, 'expires_at':expiry, 'locked_at':None})
    except Exception as error:
        if uploaded:
            client.delete_object(BUCKET, path)
        client.patch(TABLE, {'id':f'eq.{row["id"]}'}, {'status':'failed','last_error':str(error)[:1000], 'locked_at':None})
    finally:
        shutil.rmtree(root, ignore_errors=True)


def drain(args, client, repo, worker):
    # Idempotent cleanup: expired links are denied by the API even if deletion needs retrying.
    for row in client.select(TABLE, {'select':'*','expires_at':f'lte.{worker.safe_iso_now()}', 'limit':'100'}):
        try:
            # Also removes an upload interrupted before its ready-status update.
            client.delete_object(BUCKET, expected_path(row))
        except Exception as error:
            if '404' not in str(error):
                raise
        client.delete_rows(TABLE, {'id':f'eq.{row["id"]}'})
    cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=30)).isoformat()
    client.patch(TABLE, {'status':'eq.generating', 'locked_at':f'lt.{cutoff}'}, {'status':'failed', 'last_error':'Generation interrupted; please retry.', 'locked_at':None})
    rows = client.select(TABLE, {'select':'id', 'kind':'eq.tenant_comparison', 'status':'eq.queued', 'expires_at':f'gt.{worker.safe_iso_now()}', 'order':'requested_at.asc', 'limit':'3'})
    for row in rows:
        process_request(args, client, repo, row['id'], worker)
