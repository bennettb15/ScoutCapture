import Foundation

/// Session fields used by the existing write and offline-replay paths.
/// Timestamp strings retain the queue's ISO 8601 representation.
struct SessionWriteRecord: Sendable, Equatable {
    let id: UUID
    let organizationID: UUID
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
}

/// Minimal insert used when shot metadata needs its parent session row.
struct SessionInsertRecord: Sendable, Equatable {
    let id: UUID
    let organizationID: UUID
    let propertyID: UUID
    let title: String?
    let status: String
    let startedAt: String
    let completedAt: String?
    let updatedBy: UUID
}

struct SessionCaptureProfileWriteResult: Sendable, Equatable {
    let id: UUID
    let organizationID: UUID?
    let propertyID: UUID?
    let captureProfile: String?
    let updatedBy: UUID?
}

struct SessionLifecycleWrite: Sendable, Equatable {
    let status: String
    let completedAt: String?
    let exportedAt: String?
    let firstDeliveredAt: String?
}

struct SessionLifecycleWriteResult: Sendable, Equatable {
    let id: UUID
    let organizationID: UUID
    let propertyID: UUID
    let status: String?
    let updatedAt: Date?
}

protocol SessionWriteRepository {
    func upsert(_ record: SessionWriteRecord) async throws
    func update(_ record: SessionWriteRecord, propertyID: UUID, organizationID: UUID) async throws
    func insert(_ record: SessionInsertRecord) async throws
    func updateCaptureProfile(
        sessionID: UUID,
        propertyID: UUID,
        organizationID: UUID,
        profile: String,
        updatedBy: UUID?
    ) async throws -> [SessionCaptureProfileWriteResult]
    func updateLifecycle(
        _ lifecycle: SessionLifecycleWrite,
        sessionID: UUID,
        propertyID: UUID,
        organizationID: UUID
    ) async throws -> [SessionLifecycleWriteResult]
    func softDelete(sessionID: UUID) async throws
    func restore(sessionID: UUID) async throws
}
