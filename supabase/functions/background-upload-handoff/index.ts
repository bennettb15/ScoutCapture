import { handleHandoff } from "../fast-lane-report-handoff/index.ts";

type Row = Record<string, unknown>;
const pilotOrgID = "d4ba94ff-25e1-4072-aa79-9a548fcb3008";
const text = (value: unknown): string => typeof value === "string" ? value.toLowerCase().trim() : "";
const reply = (status: number, payload: Row): Response => new Response(JSON.stringify(payload), {
  status, headers: { "content-type": "application/json; charset=utf-8" },
});

async function readRows(baseURL: string, key: string, table: string, params: URLSearchParams): Promise<Row[]> {
  const response = await fetch(`${baseURL}/rest/v1/${table}?${params.toString()}`, {
    headers: { apikey: key, authorization: `Bearer ${key}`, accept: "application/json" },
  });
  if (!response.ok) throw new Error(`${table}_read_failed:${response.status}`);
  return await response.json() as Row[];
}

async function updateAttempt(baseURL: string, key: string, sessionID: string, attempts: number, error: string | null): Promise<void> {
  await fetch(`${baseURL}/rest/v1/session_upload_intents?session_id=eq.${sessionID}`, {
    method: "PATCH",
    headers: { apikey: key, authorization: `Bearer ${key}`, "content-type": "application/json" },
    body: JSON.stringify({
      attempt_count: attempts,
      last_attempt_at: new Date().toISOString(),
      last_error: error,
    }),
  });
}

async function handle(request: Request): Promise<Response> {
  if (request.method !== "POST") return reply(405, { ok: false, error: "method_not_allowed" });
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const baseURL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
  if (!key || !baseURL) return reply(503, { ok: false, error: "service_unavailable" });
  const callerKey = request.headers.get("x-scoutcapture-service-key") ?? "";
  if (!callerKey) return reply(401, { ok: false, error: "unauthorized" });
  if (callerKey !== key) {
    // GitHub may hold a different active service-role key from the Edge runtime.
    // Prove it has service_role privileges with a no-op call to the existing
    // service-only RPC; an absent session ID cannot change property status.
    const proof = await fetch(`${baseURL}/rest/v1/rpc/prepare_background_upload_handoff`, {
      method: "POST",
      headers: {
        apikey: callerKey,
        authorization: `Bearer ${callerKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ p_session_id: "00000000-0000-0000-0000-000000000000" }),
    });
    if (!proof.ok || (await proof.json()) !== false) {
      return reply(401, { ok: false, error: "unauthorized" });
    }
  }
  const summary = { examined: 0, waiting: 0, completed: 0, failed: 0 };
  try {
    for (const orgID of [pilotOrgID]) {
      const intents = await readRows(baseURL, key, "session_upload_intents", new URLSearchParams({
        select: "session_id,org_id,property_id,session_type,report_mode,expected_shot_count,attempt_count,completed_snapshot_id",
        org_id: `eq.${orgID}`, completed_snapshot_id: "is.null",
        order: "created_at.asc", limit: "50",
      }));
      for (const intent of intents) {
        summary.examined++;
        const sessionID = text(intent.session_id);
        const propertyID = text(intent.property_id);
        const expected = Number(intent.expected_shot_count);
        if (!sessionID || !propertyID || !Number.isInteger(expected) || expected <= 0) {
          summary.failed++;
          continue;
        }
        const shots = await readRows(baseURL, key, "shots", new URLSearchParams({
          select: "id,upload_state,storage_bucket,storage_path,checksum_sha256",
          org_id: `eq.${orgID}`, property_id: `eq.${propertyID}`,
          session_id: `eq.${sessionID}`, deleted_at: "is.null",
        }));
        if (shots.length !== expected || shots.some((shot) =>
          text(shot.upload_state) !== "uploaded" || !shot.storage_bucket || !shot.storage_path || !shot.checksum_sha256
        )) {
          summary.waiting++;
          continue;
        }
        const handoffRequest = new Request(`${baseURL}/functions/v1/background-upload-handoff/internal`, {
          method: "POST",
          headers: { "content-type": "application/json", "x-scoutcapture-service-key": key },
          body: JSON.stringify({
            orgID, propertyID, sessionID,
            sessionType: intent.session_type,
            reportMode: intent.report_mode,
          }),
        });
        const result = await handleHandoff(handoffRequest);
        const payload = await result.json() as Row;
        if (result.ok && payload.ok === true) {
          summary.completed++;
          await updateAttempt(baseURL, key, sessionID, Number(intent.attempt_count ?? 0) + 1, null);
        } else {
          summary.failed++;
          await updateAttempt(baseURL, key, sessionID, Number(intent.attempt_count ?? 0) + 1, text(payload.error) || `http_${result.status}`);
        }
      }
    }
    return reply(200, { ok: true, ...summary });
  } catch (error) {
    return reply(503, { ok: false, error: error instanceof Error ? error.message : "handoff_unavailable", ...summary });
  }
}

if (import.meta.main) Deno.serve(handle);
