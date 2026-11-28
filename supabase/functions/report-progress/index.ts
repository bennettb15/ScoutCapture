type JsonRecord = Record<string, unknown>;

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const text = (value: unknown): string => typeof value === "string" ? value.trim().toLowerCase() : "";
function userIDFromGatewayVerifiedJWT(token: string): string {
  try {
    const payloadPart = token.split(".")[1];
    if (!payloadPart) return "";
    const padded = payloadPart.replace(/-/g, "+").replace(/_/g, "/")
      .padEnd(Math.ceil(payloadPart.length / 4) * 4, "=");
    const payload = JSON.parse(atob(padded)) as JsonRecord;
    const userID = text(payload.sub);
    return uuidPattern.test(userID) ? userID : "";
  } catch {
    return "";
  }
}

const response = (status: number, body: JsonRecord): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });

async function selectRows<T>(url: string, serviceKey: string, table: string, query: URLSearchParams): Promise<T[]> {
  const result = await fetch(`${url}/rest/v1/${table}?${query.toString()}`, {
    headers: { apikey: serviceKey, authorization: `Bearer ${serviceKey}`, accept: "application/json" },
  });
  if (!result.ok) throw new Error(`${table}_read_failed:${result.status}`);
  return await result.json() as T[];
}

async function handle(request: Request): Promise<Response> {
  if (request.method !== "POST") return response(405, { ok: false, error: "method_not_allowed" });
  const url = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!url || !anonKey || !serviceKey) return response(500, { ok: false, error: "service_unavailable" });
  let input: JsonRecord;
  try {
    input = await request.json() as JsonRecord;
  } catch {
    return response(400, { ok: false, error: "invalid_request" });
  }
  const orgID = text(input.orgID ?? input.org_id);
  const propertyID = text(input.propertyID ?? input.property_id);
  const sessionID = text(input.sessionID ?? input.session_id);
  const snapshotID = text(input.snapshotID ?? input.snapshot_id);
  if (![orgID, propertyID, sessionID, snapshotID].every((id) => uuidPattern.test(id))) {
    return response(400, { ok: false, error: "invalid_ids" });
  }
  const token = (request.headers.get("authorization") ?? "").match(/^Bearer\s+(.+)$/i)?.[1] ?? "";
  if (!token) return response(401, { ok: false, error: "missing_authorization" });
  try {
    const auth = await fetch(`${url}/auth/v1/user`, {
      headers: { apikey: anonKey, authorization: `Bearer ${token}` },
    });
    // The gateway verifies this JWT before the function runs. Auth's user lookup
    // can be unavailable while a valid session token is still accepted, as in
    // the existing report handoff function.
    const userID = auth.ok
      ? text((await auth.json() as JsonRecord).id)
      : userIDFromGatewayVerifiedJWT(token);
    if (!uuidPattern.test(userID)) return response(401, { ok: false, error: "unauthorized" });

    const memberships = await selectRows<JsonRecord>(url, serviceKey, "org_memberships", new URLSearchParams({
      select: "id,role,access_scope", org_id: `eq.${orgID}`, user_id: `eq.${userID}`,
      deleted_at: "is.null", limit: "1",
    }));
    const membership = memberships[0];
    if (!membership) return response(403, { ok: false, error: "not_org_member" });
    if (!["owner", "manager", "field"].includes(text(membership.role)) && text(membership.access_scope) !== "org") {
      const grants = await selectRows<JsonRecord>(url, serviceKey, "property_access_grants", new URLSearchParams({
        select: "id", org_id: `eq.${orgID}`, property_id: `eq.${propertyID}`,
        user_id: `eq.${userID}`, deleted_at: "is.null", limit: "1",
      }));
      if (!grants[0]) return response(403, { ok: false, error: "no_property_access" });
    }
    const packages = await selectRows<JsonRecord>(url, serviceKey, "report_packages", new URLSearchParams({
      select: "status,manifest", org_id: `eq.${orgID}`, property_id: `eq.${propertyID}`,
      session_id: `eq.${sessionID}`, snapshot_id: `eq.${snapshotID}`, limit: "1",
    }));
    const packageRow = packages[0];
    if (!packageRow) return response(200, { ok: true, status: "queued", progress_percent: 0 });
    const status = text(packageRow.status);
    const manifest = packageRow.manifest && typeof packageRow.manifest === "object"
      ? packageRow.manifest as JsonRecord : {};
    const storedPercent = Number(manifest.progress_percent);
    const progress = status === "ready" ? 100 : Number.isFinite(storedPercent)
      ? Math.min(99, Math.max(0, Math.floor(storedPercent))) : 0;
    return response(200, { ok: true, status, progress_percent: progress });
  } catch {
    return response(503, { ok: false, error: "progress_unavailable" });
  }
}

if (import.meta.main) Deno.serve(handle);
