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

Deno.test("handoff preserves an explicit photo-only Follow-Up and infers older guided updates", () => {
  const base = {
    orgID: "d4ba94ff-25e1-4072-aa79-9a548fcb3008",
    propertyID: "1ff0eb11-5d02-4d5e-a552-1a11dee26439",
    sessionID: "028a6f82-2356-412c-a1eb-28099f240325",
    sessionType: "full_documentation",
    reportMode: "all",
  };
  const input = {
    user: { id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa" },
    property: { id: base.propertyID, org_id: base.orgID, name: "Test Property" },
    session: { id: base.sessionID, org_id: base.orgID, property_id: base.propertyID,
      started_at: "2026-11-13T18:06:00Z", completed_at: "2026-11-16T20:29:00Z", is_sealed: true },
    generatedAt: "2026-11-16T20:29:00Z",
  };
  const explicit = buildRawSessionMetadata({
    ...input,
    request: validateHandoffRequest({ ...base, fullDocumentationMode: "follow_up" }),
    shots: [{ id: "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb", capture_kind: "captured", is_guided: false }],
  });
  if (explicit.fullDocumentationMode !== "follow_up") throw new Error("photo-only Follow-Up mode missing");
  const legacy = buildRawSessionMetadata({
    ...input,
    request: validateHandoffRequest(base),
    shots: [{ id: "cccccccc-cccc-4ccc-cccc-cccccccccccc", capture_kind: "retake", is_guided: true }],
  });
  if (legacy.fullDocumentationMode !== "follow_up") throw new Error("older guided Follow-Up was not inferred");
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

Deno.test("cloud handoff reports shutter time even when shot rows were created later", () => {
  const request = validateHandoffRequest({
    orgID: "d4ba94ff-25e1-4072-aa79-9a548fcb3008",
    propertyID: "1ff0eb11-5d02-4d5e-a552-1a11dee26439",
    sessionID: "028a6f82-2356-412c-a1eb-28099f240325",
    sessionType: "full_documentation",
    reportMode: "all",
  });
  const metadata = buildRawSessionMetadata({
    request,
    user: { id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa", email: "field@example.com" },
    property: { id: request.propertyID, org_id: request.orgID, name: "Test Property" },
    session: {
      id: request.sessionID,
      org_id: request.orgID,
      property_id: request.propertyID,
      status: "completed",
      started_at: "2026-10-09T16:24:23Z",
      completed_at: "2026-10-09T16:50:00Z",
      is_sealed: true,
    },
    shots: [
      { id: "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb", created_at: "2026-10-09T16:47:00Z", captured_at: "2026-10-09T16:24:30Z" },
      { id: "cccccccc-cccc-4ccc-cccc-cccccccccccc", created_at: "2026-10-09T16:25:00Z", captured_at: "2026-10-09T16:24:25Z" },
    ],
    generatedAt: "2026-10-09T16:50:00Z",
  });
  const shots = metadata.shots as Record<string, unknown>[];
  if (shots[0].shotID !== "cccccccc-cccc-4ccc-cccc-cccccccccccc" ||
      shots[1].createdAt !== "2026-10-09T16:24:30Z" ||
      shots[1].capturedAt !== "2026-10-09T16:24:30Z") {
    throw new Error("photo order or report timestamps used row creation time");
  }
});

Deno.test("cloud handoff freezes issue state and Guided photo lifecycle", () => {
  const request = validateHandoffRequest({
    orgID: "d4ba94ff-25e1-4072-aa79-9a548fcb3008",
    propertyID: "1ff0eb11-5d02-4d5e-a552-1a11dee26439",
    sessionID: "028a6f82-2356-412c-a1eb-28099f240325",
    sessionType: "full_documentation",
    reportMode: "all",
  });
  const oldShotID = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb";
  const newShotID = "cccccccc-cccc-4ccc-cccc-cccccccccccc";
  const issueID = "dddddddd-dddd-4ddd-bddd-dddddddddddd";
  const metadata = buildRawSessionMetadata({
    request,
    user: { id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa" },
    property: { id: request.propertyID, org_id: request.orgID, name: "Test Property" },
    session: { id: request.sessionID, org_id: request.orgID, property_id: request.propertyID },
    generatedAt: "2026-11-19T12:04:00Z",
    shots: [
      { id: oldShotID, session_id: request.sessionID, is_guided: true,
        lifecycle_state: "superseded", superseded_by_shot_id: newShotID,
        replacement_reason: "guided_retake", created_at: "2026-11-19T12:00:00Z" },
      { id: newShotID, session_id: request.sessionID, issue_id: issueID,
        lifecycle_state: "active", supersedes_shot_id: oldShotID,
        created_at: "2026-11-19T12:01:00Z" },
      { id: "ffffffff-ffff-4fff-bfff-ffffffffffff", session_id: request.sessionID,
        is_guided: true, lifecycle_state: "retired", retired_reason: "duplicate",
        retired_at: "2026-11-19T12:03:00Z", building: "B1", elevation: "N",
        detail_type: "Overview", angle_index: 3, created_at: "2026-11-19T12:02:00Z" },
    ],
    observations: [{ id: issueID, status: "pending_review", title: "Loose flashing",
      priority: "high", trade: "Roofing", shot_id: newShotID }],
    observationUpdates: [{ id: "eeeeeeee-eeee-4eee-beee-eeeeeeeeeeee",
      observation_id: issueID, session_id: request.sessionID, update_type: "captured",
      status: "pending_review", created_at: "2026-11-19T12:02:00Z" }],
    guidedEvents: [{ id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaab", payload: {
      id: oldShotID, building: "B1", targetElevation: "N", detailType: "Overview",
      angleIndex: 4, skipReason: "Obstructed", skipSessionID: request.sessionID,
    } }],
  });
  const shots = metadata.shots as Record<string, unknown>[];
  const issues = metadata.issues as Record<string, unknown>[];
  const guided = metadata.guidedShots as Record<string, unknown>[];
  if (shots[0].supersededByShotID !== newShotID || shots[1].supersedesShotID !== oldShotID) {
    throw new Error("Guided replacement lineage missing from report snapshot");
  }
  if (issues.length !== 1 || issues[0].issueStatus !== "pending_review" ||
      issues[0].currentReason !== "Loose flashing" || issues[0].priority !== "high" ||
      (issues[0].historyEvents as unknown[]).length !== 1) {
    throw new Error("issue state or history missing from report snapshot");
  }
  if (guided.length !== 2 || guided[0].skipReason !== "Obstructed" ||
      guided[1].status !== "retired" || guided[1].retiredAt !== "2026-11-19T12:03:00Z") {
    throw new Error("skipped and retired Guided rows missing from report snapshot");
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
