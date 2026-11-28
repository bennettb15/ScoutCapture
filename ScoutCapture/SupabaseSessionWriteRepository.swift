import Foundation
import Supabase

struct SupabaseSessionWriteRepository: SessionWriteRepository {
    let client: SupabaseClient

    func upsert(_ record: SessionWriteRecord) async throws {
        try await client
            .from("sessions")
            .upsert(SupabaseSessionWritePayload(record: record), onConflict: "id", returning: .minimal)
            .execute()
    }

    func update(_ record: SessionWriteRecord, propertyID: UUID, organizationID: UUID) async throws {
        try await client
            .from("sessions")
            .update(SupabaseSessionWritePayload(record: record), returning: .minimal)
            .eq("id", value: record.id.uuidString.lowercased())
            .eq("property_id", value: propertyID.uuidString.lowercased())
            .eq("org_id", value: organizationID.uuidString.lowercased())
            .execute()
    }

    func insert(_ record: SessionInsertRecord) async throws {
        try await client
            .from("sessions")
            .insert(SupabaseSessionInsertPayload(record: record), returning: .minimal)
            .execute()
    }

    func updateCaptureProfile(
        sessionID: UUID,
        propertyID: UUID,
        organizationID: UUID,
        profile: String,
        updatedBy: UUID?
    ) async throws -> [SessionCaptureProfileWriteResult] {
        let rows: [SupabaseSessionCaptureProfileRow] = try await client
            .from("sessions")
            .update(
                SupabaseSessionCaptureProfilePayload(captureProfile: profile, updatedBy: updatedBy),
                returning: .representation
            )
            .eq("id", value: sessionID.uuidString.lowercased())
            .eq("property_id", value: propertyID.uuidString.lowercased())
            .eq("org_id", value: organizationID.uuidString.lowercased())
            .execute()
            .value
        return rows.map(\.writeResult)
    }

    func updateLifecycle(
        _ lifecycle: SessionLifecycleWrite,
        sessionID: UUID,
        propertyID: UUID,
        organizationID: UUID
    ) async throws -> [SessionLifecycleWriteResult] {
        let rows: [SupabaseSessionLifecycleRow] = try await client
            .from("sessions")
            .update(SupabaseSessionLifecyclePayload(lifecycle: lifecycle), returning: .representation)
            .eq("id", value: sessionID.uuidString.lowercased())
            .eq("org_id", value: organizationID.uuidString.lowercased())
            .eq("property_id", value: propertyID.uuidString.lowercased())
            .is("deleted_at", value: nil)
            .execute()
            .value
        return rows.map(\.writeResult)
    }

    func softDelete(sessionID: UUID) async throws {
        _ = try await (try client.rpc(
            "soft_delete_session",
            params: SupabaseSessionIDRPCPayload(targetSessionID: sessionID)
        )).execute()
    }

    func restore(sessionID: UUID) async throws {
        _ = try await (try client.rpc(
            "restore_session",
            params: SupabaseSessionIDRPCPayload(targetSessionID: sessionID)
        )).execute()
    }
}

struct SupabaseSessionWritePayload: Encodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let title: String?
    let status: String
    let startedAt: String
    let completedAt: String?
    let exportedAt: String?
    let isSealed: Bool?
    let firstDeliveredAt: String?
    let reExportExpiresAt: String?
    let captureProfile: String?
    let updatedBy: UUID?
    let lockedByUserID: UUID?
    let lockedByDeviceID: String?
    let lockedAt: String?
    let coordinationTier1Snapshot: String?

    init(record: SessionWriteRecord) {
        id = record.id
        orgID = record.organizationID
        propertyID = record.propertyID
        title = record.title
        status = record.status
        startedAt = record.startedAt
        completedAt = record.completedAt
        exportedAt = record.exportedAt
        isSealed = record.isSealed
        firstDeliveredAt = record.firstDeliveredAt
        reExportExpiresAt = record.reExportExpiresAt
        captureProfile = record.captureProfile
        updatedBy = record.updatedBy
        lockedByUserID = record.lockedByUserID
        lockedByDeviceID = record.lockedByDeviceID
        lockedAt = record.lockedAt
        coordinationTier1Snapshot = record.coordinationTier1Snapshot
    }

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case title
        case status
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case exportedAt = "exported_at"
        case isSealed = "is_sealed"
        case firstDeliveredAt = "first_delivered_at"
        case reExportExpiresAt = "re_export_expires_at"
        case captureProfile = "capture_profile"
        case updatedBy = "updated_by"
        case lockedByUserID = "locked_by_user_id"
        case lockedByDeviceID = "locked_by_device_id"
        case lockedAt = "locked_at"
        case coordinationTier1Snapshot = "coordination_tier1_snapshot"
    }
}

struct SupabaseSessionInsertPayload: Encodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let title: String?
    let status: String
    let startedAt: String
    let completedAt: String?
    let updatedBy: UUID

    init(record: SessionInsertRecord) {
        id = record.id
        orgID = record.organizationID
        propertyID = record.propertyID
        title = record.title
        status = record.status
        startedAt = record.startedAt
        completedAt = record.completedAt
        updatedBy = record.updatedBy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case title
        case status
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case updatedBy = "updated_by"
    }
}

private struct SupabaseSessionCaptureProfilePayload: Encodable {
    let captureProfile: String
    let updatedBy: UUID?

    enum CodingKeys: String, CodingKey {
        case captureProfile = "capture_profile"
        case updatedBy = "updated_by"
    }
}

private struct SupabaseSessionCaptureProfileRow: Decodable {
    let id: UUID
    let orgID: UUID?
    let propertyID: UUID?
    let captureProfile: String?
    let updatedBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case captureProfile = "capture_profile"
        case updatedBy = "updated_by"
    }

    var writeResult: SessionCaptureProfileWriteResult {
        SessionCaptureProfileWriteResult(
            id: id,
            organizationID: orgID,
            propertyID: propertyID,
            captureProfile: captureProfile,
            updatedBy: updatedBy
        )
    }
}

struct SupabaseSessionLifecyclePayload: Encodable {
    let status: String
    let completedAt: String?
    let exportedAt: String?
    let firstDeliveredAt: String?

    init(lifecycle: SessionLifecycleWrite) {
        status = lifecycle.status
        completedAt = lifecycle.completedAt
        exportedAt = lifecycle.exportedAt
        firstDeliveredAt = lifecycle.firstDeliveredAt
    }

    enum CodingKeys: String, CodingKey {
        case status
        case completedAt = "completed_at"
        case exportedAt = "exported_at"
        case firstDeliveredAt = "first_delivered_at"
    }
}

private struct SupabaseSessionLifecycleRow: Decodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let status: String?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case status
        case updatedAt = "updated_at"
    }

    var writeResult: SessionLifecycleWriteResult {
        SessionLifecycleWriteResult(
            id: id,
            organizationID: orgID,
            propertyID: propertyID,
            status: status,
            updatedAt: updatedAt
        )
    }
}

private struct SupabaseSessionIDRPCPayload: Encodable {
    let targetSessionID: UUID

    enum CodingKeys: String, CodingKey {
        case targetSessionID = "target_session_id"
    }
}
