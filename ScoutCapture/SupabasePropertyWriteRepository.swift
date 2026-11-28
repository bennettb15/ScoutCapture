import Foundation
import Supabase

struct SupabasePropertyWriteRepository: PropertyWriteRepository {
    let client: SupabaseClient

    func insert(_ record: PropertyWriteRecord) async throws {
        try await client
            .from("properties")
            .insert(SupabasePropertyWritePayload(record: record), returning: .minimal)
            .execute()
    }

    func upsert(_ record: PropertyWriteRecord) async throws {
        try await client
            .from("properties")
            .upsert(SupabasePropertyWritePayload(record: record), onConflict: "id", returning: .minimal)
            .execute()
    }

    func updateCaptureProfile(
        propertyID: UUID,
        organizationID: UUID,
        profile: String,
        updatedBy: UUID?,
        verify: Bool
    ) async throws -> [PropertyCaptureProfileWriteResult] {
        let payload = SupabasePropertyCaptureProfilePayload(captureProfile: profile, updatedBy: updatedBy)
        if verify {
            let rows: [SupabasePropertyCaptureProfileRow] = try await client
                .from("properties")
                .update(payload, returning: .representation)
                .eq("id", value: propertyID.uuidString.lowercased())
                .eq("org_id", value: organizationID.uuidString.lowercased())
                .execute()
                .value
            return rows.map(\.writeResult)
        }
        try await client
            .from("properties")
            .update(payload, returning: .minimal)
            .eq("id", value: propertyID.uuidString.lowercased())
            .eq("org_id", value: organizationID.uuidString.lowercased())
            .execute()
        return []
    }

    func softDelete(propertyID: UUID) async throws {
        _ = try await (try client.rpc(
            "soft_delete_property",
            params: SupabasePropertyIDRPCPayload(targetPropertyID: propertyID)
        )).execute()
    }

    func restore(propertyID: UUID) async throws {
        _ = try await (try client.rpc(
            "restore_property",
            params: SupabasePropertyIDRPCPayload(targetPropertyID: propertyID)
        )).execute()
    }
}

struct SupabasePropertyWritePayload: Encodable {
    let id: UUID
    let orgID: UUID
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

    init(record: PropertyWriteRecord) {
        id = record.id
        orgID = record.organizationID
        captureProfile = record.captureProfile
        clientName = record.clientName
        clientEmail = record.clientEmail
        clientPhone = record.clientPhone
        name = record.name
        addressLine1 = record.addressLine1
        city = record.city
        state = record.state
        postalCode = record.postalCode
        isArchived = record.isArchived
        updatedBy = record.updatedBy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case captureProfile = "capture_profile"
        case clientName = "client_name"
        case clientEmail = "client_email"
        case clientPhone = "client_phone"
        case name
        case addressLine1 = "address_line1"
        case city
        case state
        case postalCode = "postal_code"
        case isArchived = "is_archived"
        case updatedBy = "updated_by"
    }
}

private struct SupabasePropertyCaptureProfilePayload: Encodable {
    let captureProfile: String
    let updatedBy: UUID?

    enum CodingKeys: String, CodingKey {
        case captureProfile = "capture_profile"
        case updatedBy = "updated_by"
    }
}

private struct SupabasePropertyCaptureProfileRow: Decodable {
    let id: UUID
    let orgID: UUID?
    let captureProfile: String?
    let updatedBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case captureProfile = "capture_profile"
        case updatedBy = "updated_by"
    }

    var writeResult: PropertyCaptureProfileWriteResult {
        PropertyCaptureProfileWriteResult(
            id: id,
            organizationID: orgID,
            captureProfile: captureProfile,
            updatedBy: updatedBy
        )
    }
}

private struct SupabasePropertyIDRPCPayload: Encodable {
    let targetPropertyID: UUID

    enum CodingKeys: String, CodingKey {
        case targetPropertyID = "target_property_id"
    }
}
