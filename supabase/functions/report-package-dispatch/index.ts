const DEFAULT_REPOSITORY = "bennettb15/ScoutCapture";
const DEFAULT_WORKFLOW = "report-package-worker.yml";
const DEFAULT_REF = "main";

type SnapshotRecord = {
  id?: unknown;
  org_id?: unknown;
  property_id?: unknown;
  session_id?: unknown;
  snapshot_kind?: unknown;
  session_status?: unknown;
  is_sealed?: unknown;
  deleted_at?: unknown;
};

type DatabaseWebhookPayload = {
  tenant_comparison_request_id?: unknown;
  type?: unknown;
  table?: unknown;
  schema?: unknown;
  record?: SnapshotRecord;
};

function env(name: string, fallback = ""): string {
  return Deno.env.get(name)?.trim() || fallback;
}

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body, null, 2) + "\n", {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function lowerString(value: unknown): string {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function booleanValue(value: unknown): boolean {
  return value === true || lowerString(value) === "true";
}

function bearerToken(request: Request): string {
  const authorization = request.headers.get("authorization") ?? "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() ?? "";
}

function requestSecret(request: Request): string {
  return request.headers.get("x-scoutcapture-report-trigger-secret")?.trim() || bearerToken(request);
}

function timingSafeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder();
  const leftBytes = encoder.encode(left);
  const rightBytes = encoder.encode(right);
  const maxLength = Math.max(leftBytes.length, rightBytes.length);
  let difference = leftBytes.length ^ rightBytes.length;
  for (let index = 0; index < maxLength; index += 1) {
    difference |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }
  return difference === 0;
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
}

function skip(reason: string, extra: Record<string, unknown> = {}): Response {
  console.log(JSON.stringify({ event: "report_package_dispatch_skipped", reason, ...extra }));
  return jsonResponse(202, { ok: true, dispatched: false, reason, ...extra });
}

function reject(status: number, error: string, extra: Record<string, unknown> = {}): Response {
  console.warn(JSON.stringify({ event: "report_package_dispatch_rejected", reason: error, ...extra }));
  return jsonResponse(status, { ok: false, error, ...extra });
}

Deno.serve(async (request: Request): Promise<Response> => {
  if (request.method !== "POST") {
    return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  }

  let payload: DatabaseWebhookPayload;
  try { payload = await request.json(); }
  catch { return jsonResponse(400, { ok: false, error: "invalid_json" }); }
  if (payload.tenant_comparison_request_id !== undefined) {
    const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
    if (!serviceKey || !timingSafeEqual(request.headers.get("x-scoutcapture-service-key") || "", serviceKey)) {
      return reject(401, "unauthorized");
    }
    const id = lowerString(payload.tenant_comparison_request_id);
    if (!isUuid(id)) return reject(400, "invalid_request_id");
    const check = await fetch(`${env('SUPABASE_URL')}/rest/v1/on_demand_report_requests?id=eq.${id}&kind=eq.tenant_comparison&status=eq.queued&select=id`, {
      headers: { apikey: serviceKey, authorization: `Bearer ${serviceKey}` },
    });
    if (!check.ok || !(await check.json()).length) return reject(404, "request_not_found");
    const token = env("GITHUB_REPORT_WORKER_TOKEN");
    if (!token) return reject(500, "missing_github_token");
    const response = await fetch(`https://api.github.com/repos/${env('GITHUB_REPOSITORY', DEFAULT_REPOSITORY)}/actions/workflows/${env('GITHUB_REPORT_WORKER_WORKFLOW', DEFAULT_WORKFLOW)}/dispatches`, {
      method: 'POST', headers: { accept: 'application/vnd.github+json', authorization: `Bearer ${token}`, 'content-type': 'application/json', 'x-github-api-version': '2022-11-28' },
      body: JSON.stringify({ ref: env('GITHUB_REPORT_WORKER_REF', DEFAULT_REF), inputs: { tenant_comparison_request_id: id, trigger_source: 'on_demand_tenant_comparison' } }),
    });
    return jsonResponse(response.ok ? 202 : 502, { ok: response.ok, dispatched: response.ok });
  }
  const expectedSecret = env("REPORT_PACKAGE_DISPATCH_SECRET");
  if (!expectedSecret) {
    console.error(JSON.stringify({ event: "report_package_dispatch_failed", reason: "missing_dispatch_secret" }));
    return jsonResponse(500, { ok: false, error: "missing_dispatch_secret" });
  }
  if (!timingSafeEqual(requestSecret(request), expectedSecret)) {
    console.warn(JSON.stringify({ event: "report_package_dispatch_rejected", reason: "unauthorized" }));
    return jsonResponse(401, { ok: false, error: "unauthorized" });
  }

  const record = payload.record ?? {};
  const eventType = lowerString(payload.type);
  const schema = lowerString(payload.schema);
  const table = lowerString(payload.table);
  const snapshotId = lowerString(record.id);
  const sessionId = lowerString(record.session_id);
  const orgId = lowerString(record.org_id);
  const propertyId = lowerString(record.property_id);
  const snapshotKind = lowerString(record.snapshot_kind);
  const sessionStatus = lowerString(record.session_status);

  const logBase = { snapshot_id: snapshotId, session_id: sessionId, org_id: orgId, property_id: propertyId };
  if (eventType !== "insert") return skip("not_insert", { ...logBase, event_type: eventType });
  if (schema !== "public") return skip("not_public_schema", { ...logBase, schema });
  if (table !== "session_snapshots") return skip("not_session_snapshots", { ...logBase, table });
  if (!isUuid(snapshotId) || !isUuid(sessionId) || !isUuid(orgId) || !isUuid(propertyId)) {
    return reject(400, "invalid_snapshot_org_property_or_session_id", logBase);
  }
  if (snapshotKind !== "completed") return skip("not_completed_snapshot", { ...logBase, snapshot_kind: snapshotKind });
  if (sessionStatus !== "completed") return skip("session_not_completed", { ...logBase, session_status: sessionStatus });
  if (!booleanValue(record.is_sealed)) return skip("snapshot_not_sealed", logBase);
  if (record.deleted_at !== null && record.deleted_at !== undefined) return skip("snapshot_deleted", logBase);

  const token = env("GITHUB_REPORT_WORKER_TOKEN");
  if (!token) {
    console.error(JSON.stringify({ event: "report_package_dispatch_failed", reason: "missing_github_token", ...logBase }));
    return jsonResponse(500, { ok: false, error: "missing_github_token", ...logBase });
  }

  const repository = env("GITHUB_REPOSITORY", DEFAULT_REPOSITORY);
  const workflow = env("GITHUB_REPORT_WORKER_WORKFLOW", DEFAULT_WORKFLOW);
  const ref = env("GITHUB_REPORT_WORKER_REF", DEFAULT_REF);
  const dispatchUrl = `https://api.github.com/repos/${repository}/actions/workflows/${workflow}/dispatches`;
  const response = await fetch(dispatchUrl, {
    method: "POST",
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      "user-agent": "scoutcapture-report-package-dispatch",
      "x-github-api-version": "2022-11-28",
    },
    body: JSON.stringify({
      ref,
      inputs: {
        session_id: sessionId,
        snapshot_id: snapshotId,
        trigger_source: "supabase_session_snapshot_insert",
      },
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error(JSON.stringify({
      event: "report_package_dispatch_failed",
      reason: "github_dispatch_failed",
      github_status: response.status,
      github_body: errorText.slice(0, 500),
      ...logBase,
    }));
    return jsonResponse(502, { ok: false, error: "github_dispatch_failed", github_status: response.status, ...logBase });
  }

  console.log(JSON.stringify({
    event: "report_package_dispatch_sent",
    repository,
    workflow,
    ref,
    ...logBase,
  }));
  return jsonResponse(202, { ok: true, dispatched: true, repository, workflow, ref, ...logBase });
});
