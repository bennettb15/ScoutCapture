import Foundation
import Supabase

struct SupabaseSessionReadRepository: SessionReadRepository {
    let client: SupabaseClient

    private func value(_ id: UUID) -> String { id.uuidString.lowercased() }

    func ids(organizationID: UUID, propertyID: UUID, sessionID: UUID?) async throws -> [UUID] {
        var query = client.from("sessions").select("id")
            .eq("org_id", value: value(organizationID))
            .eq("property_id", value: value(propertyID))
        if let sessionID { query = query.eq("id", value: value(sessionID)) }
        let rows: [SupabaseSessionReadIDRow] = try await query.execute().value
        return rows.map(\.id)
    }

    func activityLookup(ids: [UUID]) async throws -> [SessionActivityLookupRecord] {
        guard !ids.isEmpty else { return [] }
        return try await client.from("sessions")
            .select("id, property_id, title")
            .in("id", values: ids.map(\.uuidString))
            .execute().value
    }

    func delta(organizationID: UUID, updatedAfter: Date?) async throws -> [RemoteSessionDeltaRecord] {
        var query = client.from("sessions")
            .select("id, org_id, property_id, title, status, started_at, completed_at, exported_at, is_sealed, first_delivered_at, re_export_expires_at, capture_profile, updated_at, updated_by, revision, deleted_at")
            .eq("org_id", value: value(organizationID))
        if let updatedAfter { query = query.gt("updated_at", value: Self.timestamp(updatedAfter)) }
        return try await query.order("updated_at", ascending: true).limit(500).execute().value
    }

    func updatedAt(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> Date? {
        let rows: [SupabaseSessionReadTimestampRow] = try await client.from("sessions")
            .select("id, updated_at")
            .eq("id", value: value(sessionID))
            .eq("org_id", value: value(organizationID))
            .eq("property_id", value: value(propertyID))
            .limit(1).execute().value
        return rows.first?.updatedAt
    }

    func divergence(organizationID: UUID) async throws -> [DivergenceRemoteSessionRecord] {
        try await client.from("sessions")
            .select("id, org_id, property_id, capture_profile, updated_at, deleted_at")
            .eq("org_id", value: value(organizationID))
            .limit(1_000).execute().value
    }

    func remoteOnlyDetails(organizationID: UUID) async throws -> [RemoteOnlySessionDetailSessionRecord] {
        try await client.from("sessions")
            .select("id, org_id, property_id, status, started_at, completed_at, capture_profile, updated_at, deleted_at")
            .eq("org_id", value: value(organizationID))
            .limit(1_000).execute().value
    }

    func canonical(organizationID: UUID, propertyID: UUID, sessionID: UUID?) async throws -> [CanonicalReadRemoteSessionRecord] {
        var query = client.from("sessions")
            .select("id, org_id, property_id, status, updated_at, revision, deleted_at")
            .eq("org_id", value: value(organizationID))
            .eq("property_id", value: value(propertyID))
        if let sessionID { query = query.eq("id", value: value(sessionID)) }
        return try await query.limit(25).execute().value
    }

    func canonical(ids: [UUID]) async throws -> [CanonicalReadRemoteSessionRecord] {
        guard !ids.isEmpty else { return [] }
        return try await client.from("sessions")
            .select("id, org_id, property_id, status, updated_at, revision, deleted_at")
            .in("id", values: ids.map { value($0) })
            .limit(ids.count).execute().value
    }

    func activeParent(sessionID: UUID) async throws -> SessionSnapshotRemoteSessionPreflightRow? {
        let rows: [SessionSnapshotRemoteSessionPreflightRow] = try await client.from("sessions")
            .select("id, org_id, property_id")
            .eq("id", value: value(sessionID))
            .is("deleted_at", value: nil)
            .limit(1).execute().value
        return rows.first
    }

    func lifecycle(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> RemoteSessionLifecycleReplayRecord? {
        let rows: [RemoteSessionLifecycleReplayRecord] = try await client.from("sessions")
            .select("id, org_id, property_id, status, completed_at, exported_at, is_sealed, first_delivered_at, re_export_expires_at, updated_at, deleted_at")
            .eq("org_id", value: value(organizationID))
            .eq("property_id", value: value(propertyID))
            .eq("id", value: value(sessionID))
            .limit(1).execute().value
        return rows.first
    }

    func coordination(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> RemoteSessionCoordinationRecord? {
        let rows: [RemoteSessionCoordinationRecord] = try await client.from("sessions")
            .select("id, org_id, property_id, status, completed_at, exported_at, is_sealed, first_delivered_at, re_export_expires_at, locked_by_user_id, locked_by_device_id, locked_at, coordination_tier1_snapshot, updated_at")
            .eq("org_id", value: value(organizationID))
            .eq("property_id", value: value(propertyID))
            .eq("id", value: value(sessionID))
            .limit(1).execute().value
        return rows.first
    }

    func deletePreflight(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> RemoteSessionDeletePreflightRecord? {
        let rows: [RemoteSessionDeletePreflightRecord] = try await client.from("sessions")
            .select("id, org_id, property_id, deleted_at, locked_by_user_id, locked_by_device_id, locked_at")
            .eq("org_id", value: value(organizationID))
            .eq("property_id", value: value(propertyID))
            .eq("id", value: value(sessionID))
            .limit(1).execute().value
        return rows.first
    }

    func activePropertySessions(propertyID: UUID, organizationID: UUID) async throws -> [RemotePropertySessionLockRecord] {
        try await client.from("sessions")
            .select("id, org_id, property_id, status, completed_at, exported_at, is_sealed, first_delivered_at, locked_by_user_id, locked_by_device_id, locked_at")
            .eq("org_id", value: value(organizationID))
            .eq("property_id", value: value(propertyID))
            .is("deleted_at", value: nil)
            .execute().value
    }

    func identities(organizationID: UUID) async throws -> [SessionIdentityRecord] {
        try await client.from("sessions")
            .select("id, org_id, property_id, title, status, started_at")
            .eq("org_id", value: value(organizationID))
            .execute().value
    }

    func identity(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> SessionIdentityRecord? {
        let rows: [SessionIdentityRecord] = try await client.from("sessions")
            .select("id, org_id, property_id, title, status, started_at")
            .eq("id", value: value(sessionID))
            .eq("org_id", value: value(organizationID))
            .eq("property_id", value: value(propertyID))
            .limit(1).execute().value
        return rows.first
    }

    func reportSession(sessionID: UUID, propertyID: UUID) async throws -> FastRuntimeReportRemoteSessionRecord? {
        let rows: [FastRuntimeReportRemoteSessionRecord] = try await client.from("sessions")
            .select("id, org_id, property_id, title, status, started_at, completed_at, exported_at, is_sealed, first_delivered_at, capture_profile, updated_by, deleted_at")
            .eq("id", value: value(sessionID))
            .eq("property_id", value: value(propertyID))
            .limit(1).execute().value
        return rows.first
    }

    func finalizedCandidates(propertyID: UUID, organizationID: UUID) async throws -> [RemoteSessionDeltaRecord] {
        try await client.from("sessions")
            .select("id, org_id, property_id, title, status, started_at, completed_at, exported_at, is_sealed, first_delivered_at, re_export_expires_at, capture_profile, updated_at, updated_by, revision, deleted_at")
            .eq("org_id", value: value(organizationID))
            .eq("property_id", value: value(propertyID))
            .eq("status", value: "completed")
            .is("deleted_at", value: nil)
            .order("updated_at", ascending: false)
            .limit(5).execute().value
    }

    func captureProfile(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> SessionCaptureProfileWriteResult? {
        let rows: [SupabaseSessionReadCaptureProfileRow] = try await client.from("sessions")
            .select("id, org_id, property_id, capture_profile")
            .eq("id", value: value(sessionID))
            .eq("property_id", value: value(propertyID))
            .eq("org_id", value: value(organizationID))
            .limit(1).execute().value
        return rows.first.map { row in
            SessionCaptureProfileWriteResult(id: row.id, organizationID: row.orgID, propertyID: row.propertyID, captureProfile: row.captureProfile, updatedBy: nil)
        }
    }

    func recentlyDeleted(organizationID: UUID, propertyID: UUID?) async throws -> [SessionRecentlyDeletedRecord] {
        try await (try client.rpc("fetch_recently_deleted_sessions", params: SupabaseSessionReadRecentlyDeletedParams(
            targetOrgID: organizationID,
            targetPropertyID: propertyID
        ))).execute().value
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct SupabaseSessionReadIDRow: Decodable { let id: UUID }

private struct SupabaseSessionReadTimestampRow: Decodable {
    let id: UUID
    let updatedAt: Date
    enum CodingKeys: String, CodingKey { case id; case updatedAt = "updated_at" }
}

private struct SupabaseSessionReadCaptureProfileRow: Decodable {
    let id: UUID
    let orgID: UUID?
    let propertyID: UUID?
    let captureProfile: String?
    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case captureProfile = "capture_profile"
    }
}

private struct SupabaseSessionReadRecentlyDeletedParams: Encodable {
    let targetOrgID: UUID
    let targetPropertyID: UUID?
    enum CodingKeys: String, CodingKey {
        case targetOrgID = "target_org_id"
        case targetPropertyID = "target_property_id"
    }
}
