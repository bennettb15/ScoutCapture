import Foundation

struct SessionActivityLookupRecord: Decodable {
    let id: UUID
    let propertyID: UUID
    let title: String?

    enum CodingKeys: String, CodingKey {
        case id
        case propertyID = "property_id"
        case title
    }
}

struct RemoteSessionLifecycleReplayRecord: Decodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let status: String?
    let completedAt: Date?
    let exportedAt: Date?
    let isSealed: Bool?
    let firstDeliveredAt: Date?
    let reExportExpiresAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case status
        case completedAt = "completed_at"
        case exportedAt = "exported_at"
        case isSealed = "is_sealed"
        case firstDeliveredAt = "first_delivered_at"
        case reExportExpiresAt = "re_export_expires_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct RemoteSessionCoordinationRecord: Decodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let status: String?
    let completedAt: Date?
    let exportedAt: Date?
    let isSealed: Bool?
    let firstDeliveredAt: Date?
    let reExportExpiresAt: Date?
    let lockedByUserID: UUID?
    let lockedByDeviceID: String?
    let lockedAt: String?
    let coordinationTier1Snapshot: String?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case status
        case completedAt = "completed_at"
        case exportedAt = "exported_at"
        case isSealed = "is_sealed"
        case firstDeliveredAt = "first_delivered_at"
        case reExportExpiresAt = "re_export_expires_at"
        case lockedByUserID = "locked_by_user_id"
        case lockedByDeviceID = "locked_by_device_id"
        case lockedAt = "locked_at"
        case coordinationTier1Snapshot = "coordination_tier1_snapshot"
        case updatedAt = "updated_at"
    }
}

struct RemotePropertySessionLockRecord: Decodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let status: String?
    let completedAt: Date?
    let exportedAt: Date?
    let isSealed: Bool?
    let firstDeliveredAt: Date?
    let lockedByUserID: UUID?
    let lockedByDeviceID: String?
    let lockedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case status
        case completedAt = "completed_at"
        case exportedAt = "exported_at"
        case isSealed = "is_sealed"
        case firstDeliveredAt = "first_delivered_at"
        case lockedByUserID = "locked_by_user_id"
        case lockedByDeviceID = "locked_by_device_id"
        case lockedAt = "locked_at"
    }
}

struct RemoteSessionDeletePreflightRecord: Decodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let deletedAt: Date?
    let lockedByUserID: UUID?
    let lockedByDeviceID: String?
    let lockedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case deletedAt = "deleted_at"
        case lockedByUserID = "locked_by_user_id"
        case lockedByDeviceID = "locked_by_device_id"
        case lockedAt = "locked_at"
    }
}

struct FastRuntimeReportRemoteSessionRecord: Decodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let title: String?
    let status: String?
    let startedAt: Date?
    let completedAt: Date?
    let exportedAt: Date?
    let isSealed: Bool?
    let firstDeliveredAt: Date?
    let captureProfile: String?
    let updatedBy: UUID?
    let deletedAt: Date?

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
        case captureProfile = "capture_profile"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
    }
}

struct DivergenceRemoteSessionRecord: Decodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let captureProfile: String?
    let updatedAt: Date?
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case captureProfile = "capture_profile"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct SessionIdentityRecord: Decodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let title: String?
    let status: String
    let startedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case title
        case status
        case startedAt = "started_at"
    }
}

struct RemoteSessionDeltaRecord: Decodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let title: String?
    let status: String
    let startedAt: String
    let completedAt: String?
    let exportedAt: Date?
    let isSealed: Bool?
    let firstDeliveredAt: Date?
    let reExportExpiresAt: Date?
    let captureProfile: String?
    let updatedAt: Date
    let updatedBy: UUID?
    let revision: Int64?
    let deletedAt: Date?

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
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case revision
        case deletedAt = "deleted_at"
    }
}

struct RemoteOnlySessionDetailSessionRecord: Decodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let status: String
    let startedAt: String
    let completedAt: String?
    let captureProfile: String?
    let updatedAt: Date?
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case status
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case captureProfile = "capture_profile"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct CanonicalReadRemoteSessionRecord: Decodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let status: String?
    let updatedAt: Date?
    let revision: Int64?
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case status
        case updatedAt = "updated_at"
        case revision
        case deletedAt = "deleted_at"
    }
}

struct SessionSnapshotRemoteSessionPreflightRow: Codable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
    }
}

struct SessionRecentlyDeletedRecord: Equatable, Identifiable, Decodable {
    let id: UUID
    let orgID: UUID
    let propertyID: UUID
    let status: String
    let startedAt: Date
    let endedAt: Date?
    let exportedAt: Date?
    let isSealed: Bool
    let firstDeliveredAt: Date?
    let reExportExpiresAt: Date?
    let notes: String?
    var captureProfile: String? = nil
    let deletedAt: Date
    let updatedAt: Date
    let updatedBy: UUID?
    let revision: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case propertyID = "property_id"
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case exportedAt = "exported_at"
        case isSealed = "is_sealed"
        case firstDeliveredAt = "first_delivered_at"
        case reExportExpiresAt = "re_export_expires_at"
        case notes
        case captureProfile = "capture_profile"
        case deletedAt = "deleted_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case revision
    }
}

/// All remote session reads used by the current app. Implementations may be replaced
/// without changing callers or the local-first session model.
protocol SessionReadRepository {
    func ids(organizationID: UUID, propertyID: UUID, sessionID: UUID?) async throws -> [UUID]
    func activityLookup(ids: [UUID]) async throws -> [SessionActivityLookupRecord]
    func delta(organizationID: UUID, updatedAfter: Date?) async throws -> [RemoteSessionDeltaRecord]
    func updatedAt(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> Date?
    func divergence(organizationID: UUID) async throws -> [DivergenceRemoteSessionRecord]
    func remoteOnlyDetails(organizationID: UUID) async throws -> [RemoteOnlySessionDetailSessionRecord]
    func canonical(organizationID: UUID, propertyID: UUID, sessionID: UUID?) async throws -> [CanonicalReadRemoteSessionRecord]
    func canonical(ids: [UUID]) async throws -> [CanonicalReadRemoteSessionRecord]
    func activeParent(sessionID: UUID) async throws -> SessionSnapshotRemoteSessionPreflightRow?
    func lifecycle(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> RemoteSessionLifecycleReplayRecord?
    func coordination(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> RemoteSessionCoordinationRecord?
    func deletePreflight(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> RemoteSessionDeletePreflightRecord?
    func activePropertySessions(propertyID: UUID, organizationID: UUID) async throws -> [RemotePropertySessionLockRecord]
    func identities(organizationID: UUID) async throws -> [SessionIdentityRecord]
    func identity(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> SessionIdentityRecord?
    func reportSession(sessionID: UUID, propertyID: UUID) async throws -> FastRuntimeReportRemoteSessionRecord?
    func finalizedCandidates(propertyID: UUID, organizationID: UUID) async throws -> [RemoteSessionDeltaRecord]
    func captureProfile(sessionID: UUID, propertyID: UUID, organizationID: UUID) async throws -> SessionCaptureProfileWriteResult?
    func recentlyDeleted(organizationID: UUID, propertyID: UUID?) async throws -> [SessionRecentlyDeletedRecord]
}
