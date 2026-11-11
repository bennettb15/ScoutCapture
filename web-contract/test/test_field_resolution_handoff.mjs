import test from 'node:test';
import assert from 'node:assert/strict';
import { handleHandoff } from '../../supabase/functions/fast-lane-report-handoff/index.ts';

const orgID = '11111111-1111-4111-8111-111111111111';
const propertyID = '22222222-2222-4222-8222-222222222222';
const sessionID = '33333333-3333-4333-8333-333333333333';
const issueID = '44444444-4444-4444-8444-444444444444';
const shotID = '55555555-5555-4555-8555-555555555555';
const userID = '66666666-6666-4666-8666-666666666666';
const timestamp = '2026-11-11T20:00:00Z';
const scope = { org_id: orgID, property_id: propertyID, session_id: sessionID };
const env = {
  SUPABASE_URL: 'https://example.test', SUPABASE_ANON_KEY: 'test-anon',
  SUPABASE_SERVICE_ROLE_KEY: 'test-service', REPORT_PACKAGE_DISPATCH_SECRET: 'test-dispatch',
};

for (const status of ['resolved', 'pending_review', 'failure']) {
  test(`handoff uses the atomic resolution result before snapshot and dispatch (${status})`, async (t) => {
    t.mock.method(globalThis, 'fetch', async (url, options) => {
      const { pathname: path } = new URL(url);
      const key = `${options?.method || 'GET'} ${path}`;
      calls.push(key);
      if (key === 'POST /rest/v1/rpc/finalize_field_resolution_upload') {
        assert.deepEqual(JSON.parse(options.body), {
          p_org_id: orgID, p_property_id: propertyID, p_session_id: sessionID,
        });
        return status === 'failure'
          ? new Response(null, { status: 500 })
          : Response.json([{ observation_id: issueID, shot_id: shotID, status }]);
      }
      if (key.startsWith('POST /storage/v1/object/scoutcapture-session-snapshots/')) {
        const snapshot = JSON.parse(new TextDecoder().decode(options.body));
        assert.equal(JSON.parse(snapshot.rawSessionJSON).shots[0].issueStatus, status);
        return new Response(null, { status: 201 });
      }
      if (key === 'POST /rest/v1/session_snapshots') {
        assert.deepEqual(JSON.parse(options.body).manifest.fieldResolutionSubmissions, [
          { observation_id: issueID, shot_id: shotID, status },
        ]);
        return new Response(null, { status: 201 });
      }
      if (key === 'POST /functions/v1/report-package-dispatch') return Response.json({ dispatched: true });
      assert.ok(replies.has(key), `Unexpected call: ${key}`);
      return Response.json(replies.get(key));
    });
    const originalDeno = globalThis.Deno;
    globalThis.Deno = { env: { get: (name) => env[name] } };
    t.after(() => { if (originalDeno) globalThis.Deno = originalDeno; else delete globalThis.Deno; });
    const calls = [];
    const replies = new Map([
      ['GET /auth/v1/user', { id: userID }],
      ['GET /rest/v1/org_memberships', [{ role: 'field' }]],
      ['GET /rest/v1/session_upload_intents', []],
      ['GET /rest/v1/session_snapshots', []],
      ['GET /rest/v1/properties', [{ id: propertyID, org_id: orgID, name: 'Test Property' }]],
      ['GET /rest/v1/sessions', [{
        ...scope, id: sessionID, status: 'completed', started_at: timestamp, completed_at: timestamp, is_sealed: true,
      }]],
      ['GET /rest/v1/property_status', [{
        ...scope, status: 'pending_export', pending_export_session_id: sessionID,
      }]],
      ['GET /rest/v1/shots', [{
        ...scope, id: shotID, issue_id: issueID, issue_status: 'pending_review', capture_kind: 'resolved_capture',
        is_flagged: true, upload_state: 'uploaded', storage_bucket: 'scoutcapture-originals',
        storage_path: 'test.jpg', checksum_sha256: '0'.repeat(64), byte_size: 4, created_at: timestamp,
      }]],
      ['GET /storage/v1/object/scoutcapture-originals/test.jpg', {}],
    ]);
    const response = await handleHandoff(new Request('https://example.test', {
      method: 'POST',
      headers: { authorization: 'Bearer test-user' },
      body: JSON.stringify({ orgID, propertyID, sessionID, sessionType: 'full_documentation', reportMode: 'all' }),
    }));
    const body = await response.json();
    assert.equal(response.status, status === 'failure' ? 500 : 200, JSON.stringify(body));
    const finalization = calls.indexOf('POST /rest/v1/rpc/finalize_field_resolution_upload');
    assert.ok(finalization > calls.indexOf('GET /storage/v1/object/scoutcapture-originals/test.jpg'));
    const snapshot = calls.indexOf('POST /rest/v1/session_snapshots');
    const dispatch = calls.indexOf('POST /functions/v1/report-package-dispatch');
    if (status === 'failure') {
      assert.equal(snapshot, -1);
      assert.equal(dispatch, -1);
    } else {
      assert.ok(snapshot > finalization);
      assert.ok(dispatch > snapshot);
    }
  });
}
