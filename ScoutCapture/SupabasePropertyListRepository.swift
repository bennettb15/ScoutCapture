import Foundation
import Supabase

struct SupabasePropertyListRepository: PropertyListRepository {
    let client: SupabaseClient

    func fetchProperties(organizationID: UUID) async throws -> [PropertyListRecord] {
        let rows: [SupabasePropertyRow] = try await client
            .from("properties")
            .select(
                """
                id,
                org_id,
                folder_id,
                capture_profile,
                client_name,
                client_email,
                client_phone,
                name,
                address_line1,
                city,
                state,
                postal_code,
                baseline_session_id,
                is_archived,
                deleted_at,
                created_at,
                updated_at,
                updated_by,
                revision
                """
            )
            .eq("org_id", value: organizationID.uuidString.lowercased())
            .execute()
            .value
        return rows.map(\.propertyListRecord)
    }
}

/// Supabase's column names and decoding stay inside this adapter.
struct SupabasePropertyRow: Decodable {
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

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case folderID = "folder_id"
        case captureProfile = "capture_profile"
        case clientName = "client_name"
        case clientEmail = "client_email"
        case clientPhone = "client_phone"
        case name
        case addressLine1 = "address_line1"
        case city
        case state
        case postalCode = "postal_code"
        case baselineSessionID = "baseline_session_id"
        case isArchived = "is_archived"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case revision
    }

    var propertyListRecord: PropertyListRecord {
        PropertyListRecord(
            id: id,
            orgID: orgID,
            folderID: folderID,
            captureProfile: captureProfile,
            clientName: clientName,
            clientEmail: clientEmail,
            clientPhone: clientPhone,
            name: name,
            addressLine1: addressLine1,
            city: city,
            state: state,
            postalCode: postalCode,
            baselineSessionID: baselineSessionID,
            isArchived: isArchived,
            deletedAt: deletedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            updatedBy: updatedBy,
            revision: revision
        )
    }
}
