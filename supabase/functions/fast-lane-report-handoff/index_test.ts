import {
  buildRawSessionMetadata,
  buildSnapshotPayload,
  validateHandoffRequest,
} from "./index.ts";

Deno.test("validateHandoffRequest accepts full/all and normalizes IDs", () => {
  const request = validateHandoffRequest({
    orgID: "D4BA94FF-25E1-4072-AA79-9A548FCB3008",
    propertyID: "1FF0EB11-5D02-4D5E-A552-1A11DEE26439",
    sessionID: "028A6F82-2356-412C-A1EB-28099F240325",
    sessionType: "full_documentation",
    reportMode: "all",
  });
  if (request.orgID !== "d4ba94ff-25e1-4072-aa79-9a548fcb3008") {
    throw new Error(`org id not normalized: ${request.orgID}`);
  }
  if (request.sessionType !== "full_documentation" || request.reportMode !== "all") {
    throw new Error("full request was not preserved");
  }
});

Deno.test("validateHandoffRequest rejects mismatched punch report mode", () => {
  let threw = false;
  try {
    validateHandoffRequest({
      orgID: "d4ba94ff-25e1-4072-aa79-9a548fcb3008",
      propertyID: "bd0f368c-434e-449e-827d-2e9ea1eb51d8",
      sessionID: "f19a4ecd-79ae-45a6-8618-e5c18363eaae",
      sessionType: "punchlist_visit",
      reportMode: "all",
    });
  } catch (error) {
    threw = error instanceof Error && error.message === "report_mode_mismatch_for_punchlist_visit";
  }
  if (!threw) throw new Error("expected punch/all mismatch to throw");
});

Deno.test("buildRawSessionMetadata carries punch session type and uploaded shot fields", () => {
  const request = validateHandoffRequest({
    orgID: "d4ba94ff-25e1-4072-aa79-9a548fcb3008",
    propertyID: "bd0f368c-434e-449e-827d-2e9ea1eb51d8",
    sessionID: "f19a4ecd-79ae-45a6-8618-e5c18363eaae",
    sessionType: "punchlist_visit",
    reportMode: "punchlist",
  });
  const metadata = buildRawSessionMetadata({
    request,
    user: { id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa", email: "field@example.com" },
    property: {
      id: request.propertyID,
      org_id: request.orgID,
      name: "Punch Property",
    },
    session: {
      id: request.sessionID,
      org_id: request.orgID,
      property_id: request.propertyID,
      title: "Punch Property",
      status: "completed",
      started_at: "2026-09-15T20:00:00Z",
      completed_at: "2026-09-15T20:01:00Z",
      is_sealed: true,
    },
    shots: [{
      id: "8cb52579-6752-409c-9ded-c76e8f6c11c1",
      org_id: request.orgID,
      property_id: request.propertyID,
      session_id: request.sessionID,
      created_at: "2026-09-15T20:00:30Z",
      capture_kind: "follow_up_capture",
      storage_bucket: "scoutcapture-originals",
      storage_path: "sessions/f19a4ecd-79ae-45a6-8618-e5c18363eaae/shots/8cb52579-6752-409c-9ded-c76e8f6c11c1/8cb52579-6752-409c-9ded-c76e8f6c11c1.jpg",
      checksum_sha256: "0".repeat(64),
      byte_size: 123,
      upload_state: "uploaded",
    }],
    generatedAt: "2026-09-15T20:02:00Z",
  });
  if (metadata.sessionType !== "punchlist_visit" || metadata.session_type !== "punchlist_visit") {
    throw new Error("punch session type missing from metadata");
  }
  const shots = metadata.shots as Record<string, unknown>[];
  if (shots.length !== 1 || shots[0].captureKind !== "follow_up_capture") {
    throw new Error("shot capture kind missing from metadata");
  }
});

Deno.test("buildSnapshotPayload creates completed snapshot payload and path", async () => {
  const request = validateHandoffRequest({
    orgID: "d4ba94ff-25e1-4072-aa79-9a548fcb3008",
    propertyID: "1ff0eb11-5d02-4d5e-a552-1a11dee26439",
    sessionID: "028a6f82-2356-412c-a1eb-28099f240325",
    sessionType: "full_documentation",
    reportMode: "all",
  });
  const snapshot = await buildSnapshotPayload({
    request,
    user: { id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa", email: "field@example.com" },
    property: {
      id: request.propertyID,
      org_id: request.orgID,
      name: "Full Property",
    },
    session: {
      id: request.sessionID,
      org_id: request.orgID,
      property_id: request.propertyID,
      title: "Full Property",
      status: "completed",
      started_at: "2026-09-15T20:00:00Z",
      completed_at: "2026-09-15T20:01:00Z",
      is_sealed: true,
    },
    shots: [{
      id: "cc8f5a6a-ad99-4d8e-a5ee-f9f365f4bf6f",
      org_id: request.orgID,
      property_id: request.propertyID,
      session_id: request.sessionID,
      created_at: "2026-09-15T20:00:30Z",
      capture_kind: "captured",
      storage_bucket: "scoutcapture-originals",
      storage_path: "sessions/028a6f82-2356-412c-a1eb-28099f240325/shots/cc8f5a6a-ad99-4d8e-a5ee-f9f365f4bf6f/cc8f5a6a-ad99-4d8e-a5ee-f9f365f4bf6f.jpg",
      checksum_sha256: "1".repeat(64),
      byte_size: 456,
      upload_state: "uploaded",
    }],
    snapshotID: "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb",
    generatedAt: "2026-09-15T20:02:00Z",
  });
  if (!snapshot.storagePath.endsWith("/snapshots/completed/bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb.json")) {
    throw new Error(`unexpected snapshot path: ${snapshot.storagePath}`);
  }
  if (snapshot.payload.sessionType !== "full_documentation") {
    throw new Error("payload missing full session type");
  }
  if (!/^[0-9a-f]{64}$/.test(snapshot.rawSessionJSONSHA256)) {
    throw new Error("raw session checksum missing");
  }
  if (!/^[0-9a-f]{64}$/.test(snapshot.snapshotPayloadSHA256)) {
    throw new Error("snapshot checksum missing");
  }
  if (snapshot.payloadBytes.byteLength <= 0) {
    throw new Error("payload bytes missing");
  }
});
