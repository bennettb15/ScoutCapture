import Foundation

/// Property fields that can be written without exposing a database SDK or column names.
struct PropertyWriteRecord: Sendable, Equatable {
    let id: UUID
    let organizationID: UUID
    let captureProfile: String?
    let clientName: String?
    let clientEmail: String?
    let clientPhone: String?
    let name: String
    let addressLine1: String?
    let city: String?
    let state: String?
    let postalCode: String?
    let isArchived: Bool
    let updatedBy: UUID?
}

struct PropertyCaptureProfileWriteResult: Sendable, Equatable {
    let id: UUID
    let organizationID: UUID?
    let captureProfile: String?
    let updatedBy: UUID?
}

protocol PropertyWriteRepository {
    func insert(_ record: PropertyWriteRecord) async throws
    func upsert(_ record: PropertyWriteRecord) async throws
    func updateCaptureProfile(
        propertyID: UUID,
        organizationID: UUID,
        profile: String,
        updatedBy: UUID?,
        verify: Bool
    ) async throws -> [PropertyCaptureProfileWriteResult]
    func softDelete(propertyID: UUID) async throws
    func restore(propertyID: UUID) async throws
}
