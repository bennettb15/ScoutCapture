import Foundation

/// The rows needed by the property list, independent of the backing database.
struct PropertyListRecord: Sendable {
    let id: UUID
    let orgID: UUID
    let folderID: String?
    let captureProfile: String?
    let clientName: String?
    let clientEmail: String?
    let clientPhone: String?
    let name: String
    let addressLine1: String
    let city: String
    let state: String
    let postalCode: String
    let baselineSessionID: UUID?
    let isArchived: Bool
    let deletedAt: Date?
    let createdAt: Date?
    let updatedAt: Date
    let updatedBy: UUID?
    let revision: Int64?
}

protocol PropertyListRepository {
    func fetchProperties(organizationID: UUID) async throws -> [PropertyListRecord]
}
