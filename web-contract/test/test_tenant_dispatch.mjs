import test, { after } from 'node:test';
import assert from 'node:assert/strict';

const originalFetch = globalThis.fetch;
const originalDeno = globalThis.Deno;
const values = { SUPABASE_SERVICE_ROLE_KEY: 'test-service', SUPABASE_URL: 'https://example.supabase.co', GITHUB_REPORT_WORKER_TOKEN: 'test-dispatch', REPORT_PACKAGE_DISPATCH_SECRET: 'old-webhook-secret' };
let handler;
globalThis.Deno = { env: { get: (key) => values[key] }, serve: (callback) => { handler = callback; } };
await import('../../supabase/functions/report-package-dispatch/index.ts');
after(() => { globalThis.fetch = originalFetch; if (originalDeno) globalThis.Deno = originalDeno; else delete globalThis.Deno; });
const id = '11111111-1111-1111-1111-111111111111';
const request = (key, requestId = id) => new Request('https://example.test', { method: 'POST', headers: { 'content-type': 'application/json', 'x-scoutcapture-service-key': key }, body: JSON.stringify({ tenant_comparison_request_id: requestId }) });

test('tenant dispatch requires the server service key and a queued authorized request', async () => {
  let fetchCount = 0;
  globalThis.fetch = async () => { fetchCount++; return new Response('[]', { status: 200 }); };
  assert.equal((await handler(request('wrong'))).status, 401);
  assert.equal(fetchCount, 0);
  assert.equal((await handler(request('test-service', 'invalid'))).status, 400);
  assert.equal(fetchCount, 0);
  assert.equal((await handler(request('test-service'))).status, 404);
  assert.equal(fetchCount, 1);
});
test('tenant dispatch targets the existing workflow on main without triggering a session report', async () => {
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return calls.length === 1 ? new Response(JSON.stringify([{ id }]), { status: 200 }) : new Response(null, { status: 204 });
  };
  assert.equal((await handler(request('test-service'))).status, 202);
  assert.match(calls[0].url, /kind=eq.tenant_comparison/);
  const body = JSON.parse(calls[1].options.body);
  assert.equal(body.ref, 'main');
  assert.deepEqual(body.inputs, { tenant_comparison_request_id: id, trigger_source: 'on_demand_tenant_comparison' });
});
test('the original snapshot webhook still requires its existing secret', async () => {
  const response = await handler(new Request('https://example.test', { method: 'POST', body: JSON.stringify({ type: 'INSERT', table: 'session_snapshots' }) }));
  assert.equal(response.status, 401);
});
