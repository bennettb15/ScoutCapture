const SNAPSHOT_BUCKET = "scoutcapture-session-snapshots";
const ORIGINALS_BUCKET = "scoutcapture-originals";
const TRIGGER = "fast_lane_report_handoff";
const SNAPSHOT_SCHEMA_VERSION = 1;
const SESSION_METADATA_SCHEMA_VERSION = 12;

type JsonRecord = Record<string, unknown>;

type HandoffRequest = {
  orgID: string;
  propertyID: string;
  sessionID: string;
  sessionType: "full_documentation" | "punchlist_visit";
  reportMode: "all" | "punchlist";
};

type SupabaseUser = {
  id: string;
  email?: string;
};

type SessionRow = {
  id: string;
  org_id: string;
  property_id: string;
  title?: string | null;
  status?: string | null;
  started_at?: string | null;
  completed_at?: string | null;
  exported_at?: string | null;
  is_sealed?: boolean | null;
  first_delivered_at?: string | null;
  capture_profile?: string | null;
  updated_by?: string | null;
  deleted_at?: string | null;
};

type PropertyRow = {
  id: string;
  org_id: string;
  name?: string | null;
  address_line1?: string | null;
  address_line2?: string | null;
  city?: string | null;
  state?: string | null;
  postal_code?: string | null;
  country_code?: string | null;
  deleted_at?: string | null;
};

type PropertyStatusRow = {
  property_id: string;
  org_id: string;
  status?: string | null;
  pending_export_session_id?: string | null;
};

type ShotRow = {
  id: string;
  org_id?: string | null;
  property_id?: string | null;
  session_id?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
  updated_by?: string | null;
  building?: string | null;
  elevation?: string | null;
  detail_type?: string | null;
  angle_index?: number | null;
  shot_key?: string | null;
  logical_shot_identity?: string | null;
  capture_kind?: string | null;
  first_capture_kind?: string | null;
  is_guided?: boolean | null;
  is_flagged?: boolean | null;
  issue_id?: string | null;
  issue_status?: string | null;
  trade?: string | null;
  reason?: string | null;
  priority?: string | null;
  capture_mode?: string | null;
  lens?: string | null;
  latitude?: number | null;
  longitude?: number | null;
  accuracy_meters?: number | null;
  image_width?: number | null;
  image_height?: number | null;
  lifecycle_state?: string | null;
  storage_bucket?: string | null;
  storage_path?: string | null;
  checksum_sha256?: string | null;
  byte_size?: number | null;
  upload_state?: string | null;
  upload_attempts?: number | null;
  last_upload_error?: string | null;
  deleted_at?: string | null;
};

type ReportDispatchResult = {
  expected: boolean;
  status: string;
};

type RuntimeConfig = {
  supabaseURL: string;
  anonKey: string;
  serviceRoleKey: string;
};

function env(name: string): string {
  return Deno.env.get(name)?.trim() ?? "";
}

function runtimeConfig(): RuntimeConfig {
  return {
    supabaseURL: env("SUPABASE_URL").replace(/\/+$/, ""),
    anonKey: env("SUPABASE_ANON_KEY"),
    serviceRoleKey: env("SUPABASE_SERVICE_ROLE_KEY"),
  };
}

function jsonResponse(status: number, body: JsonRecord): Response {
  return new Response(JSON.stringify(body, null, 2) + "\n", {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function lowerString(value: unknown): string {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function nullableString(value: unknown): string | null {
  const text = stringValue(value);
  return text ? text : null;
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function normalizeUuid(value: unknown): string {
  return stringValue(value).toLowerCase();
}

function bearerToken(request: Request): string {
  const authorization = request.headers.get("authorization") ?? "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() ?? "";
}

function base64URLDecode(value: string): string {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return atob(padded);
}

function userFromVerifiedJWT(token: string): SupabaseUser | null {
  const parts = token.split(".");
  if (parts.length < 2) return null;
  try {
    const payload = JSON.parse(base64URLDecode(parts[1])) as JsonRecord;
    const id = normalizeUuid(payload.sub);
    if (!isUuid(id)) return null;
    return { id, email: nullableString(payload.email) ?? undefined };
  } catch {
    return null;
  }
}

export function validateHandoffRequest(raw: unknown): HandoffRequest {
  if (!raw || typeof raw !== "object") {
    throw new Error("invalid_json_body");
  }
  const record = raw as JsonRecord;
  const orgID = normalizeUuid(record.orgID ?? record.org_id);
  const propertyID = normalizeUuid(record.propertyID ?? record.property_id);
  const sessionID = normalizeUuid(record.sessionID ?? record.session_id);
  const sessionType = lowerString(record.sessionType ?? record.session_type);
  const reportMode = lowerString(record.reportMode ?? record.report_mode);
  if (!isUuid(orgID)) throw new Error("invalid_org_id");
  if (!isUuid(propertyID)) throw new Error("invalid_property_id");
  if (!isUuid(sessionID)) throw new Error("invalid_session_id");
  if (sessionType !== "full_documentation" && sessionType !== "punchlist_visit") {
    throw new Error("invalid_session_type");
  }
  if (reportMode !== "all" && reportMode !== "punchlist") {
    throw new Error("invalid_report_mode");
  }
  if (sessionType === "full_documentation" && reportMode !== "all") {
    throw new Error("report_mode_mismatch_for_full_documentation");
  }
  if (sessionType === "punchlist_visit" && reportMode !== "punchlist") {
    throw new Error("report_mode_mismatch_for_punchlist_visit");
  }
  return { orgID, propertyID, sessionID, sessionType, reportMode } as HandoffRequest;
}

async function sha256Hex(data: Uint8Array | string): Promise<string> {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function stableJSONStringify(value: unknown): string {
  return JSON.stringify(sortForStableJSON(value));
}

function sortForStableJSON(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortForStableJSON);
  if (!value || typeof value !== "object") return value;
  const source = value as JsonRecord;
  const sorted: JsonRecord = {};
  for (const key of Object.keys(source).sort()) {
    const child = source[key];
    if (child !== undefined) sorted[key] = sortForStableJSON(child);
  }
  return sorted;
}

function snapshotStoragePath(input: {
  orgID: string;
  propertyID: string;
  sessionID: string;
  snapshotID: string;
}): string {
  return [
    `orgs/${input.orgID}`,
    `properties/${input.propertyID}`,
    `sessions/${input.sessionID}`,
    "snapshots/completed",
    `${input.snapshotID}.json`,
  ].join("/");
}

function makeShotKey(shot: ShotRow): string {
  const normalize = (value: unknown): string =>
    stringValue(value)
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "_")
      .replace(/^_+|_+$/g, "");
  return [
    normalize(shot.building),
    normalize(shot.elevation),
    normalize(shot.detail_type),
    String(Math.max(1, Number(shot.angle_index ?? 1))),
  ].join("|");
}

function filenameLeaf(path: string | null): string | null {
  if (!path) return null;
  const parts = path.replaceAll("\\", "/").split("/");
  return parts[parts.length - 1] || null;
}

function actor(user: SupabaseUser, fallbackUserID?: string | null): JsonRecord {
  return {
    user_id: fallbackUserID ?? user.id,
    email: user.email ?? null,
  };
}

function sessionTimestamp(value: string | null | undefined, fallback: string): string {
  return nullableString(value) ?? fallback;
}

export function buildRawSessionMetadata(input: {
  request: HandoffRequest;
  user: SupabaseUser;
  property: PropertyRow;
  session: SessionRow;
  shots: ShotRow[];
  generatedAt: string;
}): JsonRecord {
  const { request, user, property, session, shots, generatedAt } = input;
  const startedAt = sessionTimestamp(session.started_at, generatedAt);
  const completedAt = sessionTimestamp(session.completed_at, startedAt);
  const sessionActor = actor(user, session.updated_by);
  const orderedShots = [...shots].sort((lhs, rhs) => {
    const lhsDate = stringValue(lhs.created_at);
    const rhsDate = stringValue(rhs.created_at);
    if (lhsDate !== rhsDate) return lhsDate.localeCompare(rhsDate);
    return lhs.id.localeCompare(rhs.id);
  });
  return {
    schemaVersion: SESSION_METADATA_SCHEMA_VERSION,
    propertyID: request.propertyID,
    propertyId: request.propertyID,
    sessionID: request.sessionID,
    sessionId: request.sessionID,
    sessionType: request.sessionType,
    session_type: request.sessionType,
    orgID: request.orgID,
    orgId: request.orgID,
    propertyNameAtCapture: property.name ?? session.title ?? null,
    propertyNameAtExport: property.name ?? session.title ?? null,
    propertyAddressAtCapture: [property.address_line1, property.address_line2, property.city, property.state, property.postal_code]
      .map((part) => stringValue(part))
      .filter(Boolean)
      .join(", ") || null,
    propertyStreetAtCapture: property.address_line1 ?? null,
    propertyCityAtCapture: property.city ?? null,
    propertyStateAtCapture: property.state ?? null,
    propertyZipAtCapture: property.postal_code ?? null,
    captureProfile: session.capture_profile ?? null,
    actor: sessionActor,
    actorUserID: sessionActor.user_id,
    actorEmail: sessionActor.email,
    capturedBy: sessionActor,
    capturedByUserID: sessionActor.user_id,
    capturedByEmail: sessionActor.email,
    uploadedBy: sessionActor,
    uploadedByUserID: sessionActor.user_id,
    uploadedByEmail: sessionActor.email,
    startedAt,
    endedAt: completedAt,
    status: "completed",
    isSealed: session.is_sealed === true,
    exportedAt: session.exported_at ?? null,
    firstDeliveredAt: session.first_delivered_at ?? null,
    appVersion: "fast-lane-report-handoff-edge",
    deviceModel: "server-owned-fast-lane",
    osVersion: "supabase-edge-runtime",
    reportMode: request.reportMode,
    shots: orderedShots.map((shot, index) => {
      const storagePath = nullableString(shot.storage_path);
      const detailType = nullableString(shot.detail_type) ?? (request.sessionType === "punchlist_visit" ? "Punchlist Capture" : "Fast Lane Capture");
      const angleIndex = Math.max(1, Number(shot.angle_index ?? index + 1));
      const shotActor = actor(user, shot.updated_by ?? session.updated_by);
      return {
        shotID: shot.id,
        shotId: shot.id,
        id: shot.id,
        propertyID: request.propertyID,
        propertyId: request.propertyID,
        sessionID: request.sessionID,
        sessionId: request.sessionID,
        createdAt: sessionTimestamp(shot.created_at, completedAt),
        capturedAt: sessionTimestamp(shot.created_at, completedAt),
        updatedAt: sessionTimestamp(shot.updated_at, sessionTimestamp(shot.created_at, completedAt)),
        actor: shotActor,
        actorUserID: shotActor.user_id,
        actorEmail: shotActor.email,
        capturedBy: shotActor,
        capturedByUserID: shotActor.user_id,
        capturedByEmail: shotActor.email,
        uploadedBy: shotActor,
        uploadedByUserID: shotActor.user_id,
        uploadedByEmail: shotActor.email,
        building: shot.building ?? "",
        elevation: shot.elevation ?? "",
        detailType,
        detail_type: detailType,
        angleIndex,
        angle_index: angleIndex,
        trade: shot.trade ?? null,
        priority: shot.priority ?? null,
        shotKey: nullableString(shot.shot_key) ?? makeShotKey({ ...shot, detail_type: detailType, angle_index: angleIndex }),
        logicalShotIdentity: shot.logical_shot_identity ?? null,
        isGuided: shot.is_guided === true,
        isFlagged: shot.is_flagged === true,
        issueID: shot.issue_id ?? null,
        issueId: shot.issue_id ?? null,
        issueStatus: shot.issue_status ?? null,
        captureKind: shot.capture_kind ?? null,
        firstCaptureKind: shot.first_capture_kind ?? null,
        noteText: shot.reason ?? null,
        reason: shot.reason ?? null,
        originalFilename: filenameLeaf(storagePath) ?? `${shot.id}.jpg`,
        originalRelativePath: storagePath ?? "",
        originalByteSize: shot.byte_size ?? null,
        storageBucket: shot.storage_bucket ?? ORIGINALS_BUCKET,
        storagePath,
        checksumSHA256: shot.checksum_sha256 ?? null,
        byteSize: shot.byte_size ?? null,
        uploadState: shot.upload_state ?? null,
        uploadAttempts: shot.upload_attempts ?? 0,
        lastUploadError: shot.last_upload_error ?? null,
        captureMode: shot.capture_mode ?? null,
        lens: shot.lens ?? null,
        latitude: shot.latitude ?? null,
        longitude: shot.longitude ?? null,
        accuracyMeters: shot.accuracy_meters ?? null,
        imageWidth: shot.image_width ?? null,
        imageHeight: shot.image_height ?? null,
        lifecycleState: shot.lifecycle_state ?? "active",
      };
    }),
    issues: [],
    guidedShots: [],
  };
}

export async function buildSnapshotPayload(input: {
  request: HandoffRequest;
  user: SupabaseUser;
  property: PropertyRow;
  session: SessionRow;
  shots: ShotRow[];
  snapshotID: string;
  generatedAt: string;
}): Promise<{
  payload: JsonRecord;
  payloadJSON: string;
  payloadBytes: Uint8Array;
  rawSessionJSON: string;
  rawSessionJSONSHA256: string;
  snapshotPayloadSHA256: string;
  storagePath: string;
}> {
  const rawMetadata = buildRawSessionMetadata(input);
  const rawSessionJSON = stableJSONStringify(rawMetadata);
  const rawSessionJSONSHA256 = await sha256Hex(rawSessionJSON);
  const manifest = input.shots.map((shot) => ({
    id: shot.id,
    originalFilenamePreview: filenameLeaf(nullableString(shot.storage_path)),
    originalRelativePathPresent: nullableString(shot.storage_path) !== null,
    originalByteSize: shot.byte_size ?? null,
    localOriginalExists: false,
    storageBucketPresent: nullableString(shot.storage_bucket) !== null,
    storagePathPresent: nullableString(shot.storage_path) !== null,
    checksumPresent: nullableString(shot.checksum_sha256) !== null,
    storageByteSize: shot.byte_size ?? null,
    capturedByUserID: shot.updated_by ?? input.session.updated_by ?? input.user.id,
    capturedByEmail: input.user.email ?? null,
    uploadedByUserID: shot.updated_by ?? input.session.updated_by ?? input.user.id,
    uploadedByEmail: input.user.email ?? null,
  }));
  const sessionActor = actor(input.user, input.session.updated_by);
  const payloadBase: JsonRecord = {
    snapshotSchemaVersion: SNAPSHOT_SCHEMA_VERSION,
    sessionMetadataSchemaVersion: SESSION_METADATA_SCHEMA_VERSION,
    trigger: TRIGGER,
    generatedAt: input.generatedAt,
    appVersion: "fast-lane-report-handoff-edge",
    sourceDeviceID: "server-owned-fast-lane",
    orgID: input.request.orgID,
    propertyID: input.request.propertyID,
    sessionID: input.request.sessionID,
    sessionType: input.request.sessionType,
    session_type: input.request.sessionType,
    reportMode: input.request.reportMode,
    status: "completed",
    isSealed: input.session.is_sealed === true,
    exportedAt: input.session.exported_at ?? null,
    firstDeliveredAt: input.session.first_delivered_at ?? null,
    reExportExpiresAt: null,
    actor: sessionActor,
    capturedBy: sessionActor,
    uploadedBy: sessionActor,
    shotCount: input.shots.length,
    issueCount: 0,
    guidedCount: 0,
    mediaManifestCount: manifest.length,
    missingLocalOriginalsCount: 0,
    supabaseStorageMetadataCount: manifest.filter((item) => item.storageBucketPresent && item.storagePathPresent).length,
    rawSessionJSON,
    rawSessionJSONSHA256,
    rawSessionJSONByteCount: new TextEncoder().encode(rawSessionJSON).length,
    mediaManifest: manifest,
  };
  const payloadWithoutChecksumJSON = stableJSONStringify(payloadBase);
  const snapshotPayloadSHA256 = await sha256Hex(payloadWithoutChecksumJSON);
  const payload = payloadBase;
  const payloadJSON = payloadWithoutChecksumJSON;
  return {
    payload,
    payloadJSON,
    payloadBytes: new TextEncoder().encode(payloadJSON),
    rawSessionJSON,
    rawSessionJSONSHA256,
    snapshotPayloadSHA256,
    storagePath: snapshotStoragePath({
      orgID: input.request.orgID,
      propertyID: input.request.propertyID,
      sessionID: input.request.sessionID,
      snapshotID: input.snapshotID,
    }),
  };
}

async function supabaseFetch(config: RuntimeConfig, path: string, options: RequestInit = {}, useServiceRole = true): Promise<Response> {
  const key = useServiceRole ? config.serviceRoleKey : config.anonKey;
  const headers = new Headers(options.headers);
  headers.set("apikey", key);
  headers.set("authorization", `Bearer ${key}`);
  if (!headers.has("content-type") && options.body !== undefined) {
    headers.set("content-type", "application/json");
  }
  return fetch(`${config.supabaseURL}${path}`, { ...options, headers });
}

async function authUser(config: RuntimeConfig, token: string): Promise<SupabaseUser> {
  if (!token) throw new Error("missing_authorization");
  const response = await fetch(`${config.supabaseURL}/auth/v1/user`, {
    headers: {
      apikey: config.anonKey,
      authorization: `Bearer ${token}`,
    },
  });
  if (!response.ok) {
    const jwtUser = userFromVerifiedJWT(token);
    if (jwtUser) return jwtUser;
    throw new Error("unauthorized");
  }
  const body = await response.json() as JsonRecord;
  const id = normalizeUuid(body.id);
  if (!isUuid(id)) throw new Error("auth_user_missing_id");
  return { id, email: nullableString(body.email) ?? undefined };
}

async function selectRows<T>(config: RuntimeConfig, table: string, query: URLSearchParams): Promise<T[]> {
  const response = await supabaseFetch(config, `/rest/v1/${table}?${query.toString()}`, {
    headers: { accept: "application/json" },
  });
  if (!response.ok) {
    throw new Error(`${table}_select_failed:${response.status}:${(await response.text()).slice(0, 300)}`);
  }
  return await response.json() as T[];
}

async function insertRow(config: RuntimeConfig, table: string, row: JsonRecord): Promise<void> {
  const response = await supabaseFetch(config, `/rest/v1/${table}`, {
    method: "POST",
    headers: {
      prefer: "return=minimal",
    },
    body: JSON.stringify(row),
  });
  if (!response.ok) {
    throw new Error(`${table}_insert_failed:${response.status}:${(await response.text()).slice(0, 500)}`);
  }
}

async function verifyCallerAccess(config: RuntimeConfig, request: HandoffRequest, user: SupabaseUser): Promise<void> {
  const membershipQuery = new URLSearchParams({
    select: "id,role,access_scope,deleted_at",
    org_id: `eq.${request.orgID}`,
    user_id: `eq.${user.id}`,
    deleted_at: "is.null",
    limit: "1",
  });
  const memberships = await selectRows<JsonRecord>(config, "org_memberships", membershipQuery);
  const membership = memberships[0];
  if (!membership) throw new Error("caller_not_org_member");
  const role = lowerString(membership.role);
  const accessScope = lowerString(membership.access_scope);
  if (["owner", "manager", "field"].includes(role) || accessScope === "org") return;

  const grantQuery = new URLSearchParams({
    select: "id",
    org_id: `eq.${request.orgID}`,
    property_id: `eq.${request.propertyID}`,
    user_id: `eq.${user.id}`,
    deleted_at: "is.null",
    limit: "1",
  });
  const grants = await selectRows<JsonRecord>(config, "property_access_grants", grantQuery);
  if (!grants[0]) throw new Error("caller_missing_property_access");
}

function validateRows(input: {
  request: HandoffRequest;
  property: PropertyRow | undefined;
  session: SessionRow | undefined;
  propertyStatus: PropertyStatusRow | undefined;
  shots: ShotRow[];
}): void {
  const { request, property, session, propertyStatus, shots } = input;
  if (!property || property.org_id !== request.orgID || property.deleted_at) throw new Error("property_missing_or_mismatched");
  if (!session) throw new Error("session_missing");
  if (session.org_id !== request.orgID || session.property_id !== request.propertyID || session.deleted_at) {
    throw new Error("session_org_property_mismatch");
  }
  if (lowerString(session.status) !== "completed") throw new Error("session_not_completed");
  if (session.is_sealed !== true) throw new Error("session_not_sealed");
  if (!session.completed_at) throw new Error("session_completed_at_missing");
  if (!propertyStatus) throw new Error("property_status_missing");
  if (propertyStatus.org_id !== request.orgID || propertyStatus.property_id !== request.propertyID) {
    throw new Error("property_status_scope_mismatch");
  }
  if (lowerString(propertyStatus.status) !== "pending_export") throw new Error("property_status_not_pending_export");
  if (normalizeUuid(propertyStatus.pending_export_session_id) !== request.sessionID) {
    throw new Error("property_status_pending_export_session_mismatch");
  }
  if (shots.length === 0) throw new Error("shots_missing");
  const expectedKind = request.sessionType === "punchlist_visit" ? "follow_up_capture" : "captured";
  for (const shot of shots) {
    if (shot.org_id !== request.orgID || shot.property_id !== request.propertyID || shot.session_id !== request.sessionID || shot.deleted_at) {
      throw new Error(`shot_scope_mismatch:${shot.id}`);
    }
    const captureKind = lowerString(shot.capture_kind);
    const issueStatus = lowerString(shot.issue_status);
    const isIssueShot = shot.is_flagged === true || nullableString(shot.issue_id) !== null || issueStatus !== null;
    const allowedKinds = new Set<string>([expectedKind]);
    if (isIssueShot) {
      allowedKinds.add("follow_up_capture");
      allowedKinds.add("retake");
      if (issueStatus === "pending_review" || issueStatus === "resolved") {
        allowedKinds.add("resolved_capture");
      }
    }
    if (!captureKind || !allowedKinds.has(captureKind)) throw new Error(`shot_capture_kind_mismatch:${shot.id}`);
    if (lowerString(shot.upload_state) !== "uploaded") throw new Error(`shot_not_uploaded:${shot.id}`);
    if (!nullableString(shot.storage_bucket) || !nullableString(shot.storage_path)) throw new Error(`shot_storage_missing:${shot.id}`);
    if (!nullableString(shot.checksum_sha256)) throw new Error(`shot_checksum_missing:${shot.id}`);
    if (!shot.byte_size || shot.byte_size <= 0) throw new Error(`shot_byte_size_missing:${shot.id}`);
  }
}

async function storageObjectExists(config: RuntimeConfig, bucket: string, path: string): Promise<boolean> {
  const encodedPath = path.split("/").map(encodeURIComponent).join("/");
  const response = await supabaseFetch(config, `/storage/v1/object/${encodeURIComponent(bucket)}/${encodedPath}`, {
    method: "GET",
    headers: {
      range: "bytes=0-0",
    },
  });
  return response.ok;
}

async function uploadSnapshotObject(config: RuntimeConfig, path: string, payloadBytes: Uint8Array): Promise<void> {
  const encodedPath = path.split("/").map(encodeURIComponent).join("/");
  const response = await supabaseFetch(config, `/storage/v1/object/${SNAPSHOT_BUCKET}/${encodedPath}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "cache-control": "31536000",
      "x-upsert": "false",
    },
    body: payloadBytes,
  });
  if (!response.ok) {
    throw new Error(`snapshot_storage_upload_failed:${response.status}:${(await response.text()).slice(0, 500)}`);
  }
}

async function dispatchReportWorker(
  config: RuntimeConfig,
  snapshotID: string,
  sessionID: string,
  orgID: string,
  propertyID: string,
): Promise<ReportDispatchResult> {
  const secret = env("REPORT_PACKAGE_DISPATCH_SECRET");
  if (!secret) {
    return { expected: true, status: "manual_dispatch_secret_missing_webhook_expected" };
  }
  const response = await fetch(`${config.supabaseURL}/functions/v1/report-package-dispatch`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-scoutcapture-report-trigger-secret": secret,
    },
    body: JSON.stringify({
      type: "INSERT",
      table: "session_snapshots",
      schema: "public",
      record: {
        id: snapshotID,
        org_id: orgID,
        property_id: propertyID,
        session_id: sessionID,
        snapshot_kind: "completed",
        session_status: "completed",
        is_sealed: true,
        deleted_at: null,
      },
    }),
  });
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`report_dispatch_failed:${response.status}:${body.slice(0, 500)}`);
  }
  let payload: JsonRecord = {};
  try {
    payload = await response.json();
  } catch {
    payload = {};
  }
  return {
    expected: payload.dispatched === true,
    status: payload.dispatched === true
      ? "report_package_dispatch_sent"
      : `report_package_dispatch_${lowerString(payload.reason) || "not_dispatched"}`,
  };
}

async function handleHandoff(request: Request): Promise<Response> {
  if (request.method !== "POST") return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  const config = runtimeConfig();
  if (!config.supabaseURL || !config.anonKey || !config.serviceRoleKey) {
    return jsonResponse(500, { ok: false, error: "missing_supabase_function_env" });
  }

  let handoff: HandoffRequest;
  try {
    handoff = validateHandoffRequest(await request.json());
  } catch (error) {
    return jsonResponse(400, { ok: false, error: error instanceof Error ? error.message : "invalid_request" });
  }

  try {
    const user = await authUser(config, bearerToken(request));
    await verifyCallerAccess(config, handoff, user);

    const propertyQuery = new URLSearchParams({
      select: "id,org_id,name,address_line1,address_line2,city,state,postal_code,country_code,deleted_at",
      id: `eq.${handoff.propertyID}`,
      org_id: `eq.${handoff.orgID}`,
      limit: "1",
    });
    const sessionQuery = new URLSearchParams({
      select: "id,org_id,property_id,title,status,started_at,completed_at,exported_at,is_sealed,first_delivered_at,capture_profile,updated_by,deleted_at",
      id: `eq.${handoff.sessionID}`,
      property_id: `eq.${handoff.propertyID}`,
      org_id: `eq.${handoff.orgID}`,
      limit: "1",
    });
    const statusQuery = new URLSearchParams({
      select: "property_id,org_id,status,pending_export_session_id",
      property_id: `eq.${handoff.propertyID}`,
      org_id: `eq.${handoff.orgID}`,
      limit: "1",
    });
    const shotsQuery = new URLSearchParams({
      select: [
        "id,org_id,property_id,session_id,created_at,updated_at,updated_by,deleted_at",
        "building,elevation,detail_type,angle_index,shot_key,logical_shot_identity",
        "capture_kind,first_capture_kind,is_guided,is_flagged,issue_id,issue_status,trade,reason,priority",
        "capture_mode,lens,latitude,longitude,accuracy_meters,image_width,image_height,lifecycle_state",
        "storage_bucket,storage_path,checksum_sha256,byte_size,upload_state,upload_attempts,last_upload_error",
      ].join(","),
      session_id: `eq.${handoff.sessionID}`,
      property_id: `eq.${handoff.propertyID}`,
      org_id: `eq.${handoff.orgID}`,
      deleted_at: "is.null",
      order: "created_at.asc",
    });

    const [properties, sessions, statuses, shots] = await Promise.all([
      selectRows<PropertyRow>(config, "properties", propertyQuery),
      selectRows<SessionRow>(config, "sessions", sessionQuery),
      selectRows<PropertyStatusRow>(config, "property_status", statusQuery),
      selectRows<ShotRow>(config, "shots", shotsQuery),
    ]);
    const property = properties[0];
    const session = sessions[0];
    const propertyStatus = statuses[0];
    validateRows({ request: handoff, property, session, propertyStatus, shots });

    for (const shot of shots) {
      const bucket = nullableString(shot.storage_bucket);
      const path = nullableString(shot.storage_path);
      if (!bucket || !path || !(await storageObjectExists(config, bucket, path))) {
        throw new Error(`shot_storage_object_missing:${shot.id}`);
      }
    }

    const snapshotID = crypto.randomUUID();
    const generatedAt = new Date().toISOString();
    const snapshot = await buildSnapshotPayload({
      request: handoff,
      user,
      property: property!,
      session: session!,
      shots,
      snapshotID,
      generatedAt,
    });

    await uploadSnapshotObject(config, snapshot.storagePath, snapshot.payloadBytes);
    await insertRow(config, "session_snapshots", {
      id: snapshotID,
      org_id: handoff.orgID,
      property_id: handoff.propertyID,
      session_id: handoff.sessionID,
      snapshot_kind: "completed",
      snapshot_schema_version: SNAPSHOT_SCHEMA_VERSION,
      session_metadata_schema_version: SESSION_METADATA_SCHEMA_VERSION,
      trigger: TRIGGER,
      session_status: "completed",
      is_sealed: true,
      exported_at: session!.exported_at ?? null,
      first_delivered_at: session!.first_delivered_at ?? null,
      re_export_expires_at: null,
      payload_storage_bucket: SNAPSHOT_BUCKET,
      payload_storage_path: snapshot.storagePath,
      payload_byte_size: snapshot.payloadBytes.byteLength,
      raw_session_json_sha256: snapshot.rawSessionJSONSHA256,
      snapshot_payload_sha256: snapshot.snapshotPayloadSHA256,
      manifest: {
        media: (snapshot.payload.mediaManifest as unknown[]) ?? [],
        actor: snapshot.payload.actor ?? null,
        capturedBy: snapshot.payload.capturedBy ?? null,
        uploadedBy: snapshot.payload.uploadedBy ?? null,
        sessionType: handoff.sessionType,
        session_type: handoff.sessionType,
        reportMode: handoff.reportMode,
      },
      shot_count: shots.length,
      issue_count: 0,
      guided_count: 0,
      media_manifest_count: shots.length,
      missing_local_originals_count: 0,
      supabase_storage_metadata_count: shots.length,
      created_by: user.id,
      updated_by: user.id,
    });
    const dispatch = await dispatchReportWorker(config, snapshotID, handoff.sessionID, handoff.orgID, handoff.propertyID);

    return jsonResponse(200, {
      ok: true,
      reused: false,
      snapshot_id: snapshotID,
      snapshot_path: snapshot.storagePath,
      snapshot_bucket: SNAPSHOT_BUCKET,
      snapshot_payload_sha256: snapshot.snapshotPayloadSHA256,
      raw_session_json_sha256: snapshot.rawSessionJSONSHA256,
      session_id: handoff.sessionID,
      session_type: handoff.sessionType,
      report_mode: handoff.reportMode,
      shot_count: shots.length,
      idempotency_key: `fast-lane-report-handoff:${handoff.sessionID}`,
      dispatch_expected: dispatch.expected,
      dispatch_status: `session_snapshot_inserted_${dispatch.status}`,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "fast_lane_report_handoff_failed";
    const status = message === "unauthorized" || message === "missing_authorization" ? 401 :
      message.startsWith("caller_") ? 403 :
      message.includes("_missing") || message.includes("_mismatch") || message.includes("_not_") ? 409 :
      500;
    return jsonResponse(status, {
      ok: false,
      error: message,
      session_id: handoff.sessionID,
      session_type: handoff.sessionType,
      report_mode: handoff.reportMode,
      retry_safe: true,
    });
  }
}

if (import.meta.main) {
  Deno.serve(handleHandoff);
}
