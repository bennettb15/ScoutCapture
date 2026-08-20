import XCTest
@testable import ScoutCapture

final class OrganizationContactPersistenceTests: XCTestCase {
    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-OrgContacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testPrimaryContactCandidatesPersistAcrossStoreInstancesAndHubIndexReads() throws {
        let root = try makeTempStorageRoot()
        let orgA = Organization(id: UUID(), name: "Test Org")
        let orgB = Organization(id: UUID(), name: "Other Org")
        let store = LocalStore(testStorageRootURL: root)

        _ = try store.createOrganization(orgA)
        _ = try store.createOrganization(orgB)
        _ = try store.createProperty(Property(
            orgId: orgA.id,
            clientName: "Jane Smith",
            clientPhone: "5551234567",
            clientEmail: "jane@example.com",
            name: "Property A"
        ))
        _ = try store.createProperty(Property(
            orgId: orgA.id,
            clientName: " jane smith ",
            clientPhone: "5551234567",
            clientEmail: "JANE@example.com",
            name: "Property B"
        ))
        _ = try store.createProperty(Property(
            orgId: orgB.id,
            clientName: "Chris Lee",
            name: "Property C"
        ))

        let relaunchedStore = LocalStore(testStorageRootURL: root)
        let organizations = try relaunchedStore.fetchOrganizations()
        let orgAContacts = contacts(in: organizations, organizationID: orgA.id)
        let orgBContacts = contacts(in: organizations, organizationID: orgB.id)

        XCTAssertEqual(orgAContacts.count, 1)
        XCTAssertEqual(orgAContacts.first?.name.lowercased(), "jane smith")
        XCTAssertFalse(orgBContacts.contains { $0.name.localizedCaseInsensitiveCompare("Jane Smith") == .orderedSame })

        let cachedState = try XCTUnwrap(relaunchedStore.fetchPropertyAndOrganizationStateFromLocalHubIndexCache())
        let cachedOrgAContacts = contacts(in: cachedState.organizations, organizationID: orgA.id)
        let cachedOrgBContacts = contacts(in: cachedState.organizations, organizationID: orgB.id)

        XCTAssertEqual(cachedOrgAContacts.count, 1)
        XCTAssertEqual(cachedOrgAContacts.first?.name.lowercased(), "jane smith")
        XCTAssertFalse(cachedOrgBContacts.contains { $0.name.localizedCaseInsensitiveCompare("Jane Smith") == .orderedSame })
    }

    func testOrganizationsWithoutContactsAreRepairedFromDurablePropertyData() throws {
        let root = try makeTempStorageRoot()
        let org = Organization(id: UUID(), name: "Repair Org")
        let store = LocalStore(testStorageRootURL: root)
        _ = try store.createOrganization(org)
        _ = try store.createProperty(Property(
            orgId: org.id,
            clientName: "Saved Client",
            clientPhone: "5550001111",
            clientEmail: "saved@example.com",
            name: "Existing Property"
        ))

        let organizationsURL = root
            .appendingPathComponent("SCOUT", isDirectory: true)
            .appendingPathComponent("organizations.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([Organization(id: org.id, name: org.name, contacts: [])])
            .write(to: organizationsURL, options: .atomic)

        let repairedStore = LocalStore(testStorageRootURL: root)
        let repairedContacts = contacts(in: try repairedStore.fetchOrganizations(), organizationID: org.id)

        XCTAssertEqual(repairedContacts.map(\.name), ["Saved Client"])
    }

    func testLegacyHubIndexWithoutContactsDerivesCandidatesFromPropertyRows() throws {
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let orgAID = UUID()
        let orgBID = UUID()
        let generatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let index = LegacyHubIndexFixture(
            generatedAt: generatedAt,
            properties: [
                LegacyPropertyRow(
                    id: UUID(),
                    orgId: orgAID,
                    folderId: "0001",
                    clientName: "Existing Client",
                    clientPhone: "5552223333",
                    clientEmail: "existing@example.com",
                    name: "Legacy Property",
                    createdAt: generatedAt,
                    updatedAt: generatedAt
                ),
                LegacyPropertyRow(
                    id: UUID(),
                    orgId: orgBID,
                    folderId: "0002",
                    clientName: "Other Client",
                    clientPhone: nil,
                    clientEmail: nil,
                    name: "Other Property",
                    createdAt: generatedAt,
                    updatedAt: generatedAt
                )
            ],
            organizations: [
                LegacyOrganizationRow(id: orgAID, name: "Legacy Org"),
                LegacyOrganizationRow(id: orgBID, name: "Other Org")
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let cacheURL = root.appendingPathComponent("local-hub-index.json", isDirectory: false)
        try encoder.encode(index).write(to: cacheURL, options: .atomic)

        let cachedState = try XCTUnwrap(store.fetchPropertyAndOrganizationStateFromLocalHubIndexCache())
        let orgAContacts = contacts(in: cachedState.organizations, organizationID: orgAID)
        let orgBContacts = contacts(in: cachedState.organizations, organizationID: orgBID)

        XCTAssertEqual(orgAContacts.map(\.name), ["Existing Client"])
        XCTAssertFalse(orgBContacts.contains { $0.name.localizedCaseInsensitiveCompare("Existing Client") == .orderedSame })
    }

    func testLegacySessionPrimaryContactRepairsExistingOrganizationContacts() throws {
        let root = try makeTempStorageRoot()
        let organization = Organization(id: UUID(), name: "Legacy Client Org")
        let store = LocalStore(testStorageRootURL: root)
        _ = try store.createOrganization(organization)

        try writeLegacySessionMetadata(
            root: root,
            propertyID: UUID(),
            sessionID: UUID(),
            values: [
                "orgID": organization.id.uuidString,
                "orgNameAtCapture": organization.name,
                "primaryContactName": "Historical Contact",
                "primaryContactEmail": "historical@example.com",
                "primaryContactPhone": "5551112222"
            ]
        )

        let repairedContacts = contacts(in: try store.fetchOrganizations(), organizationID: organization.id)

        XCTAssertEqual(repairedContacts.map(\.name), ["Historical Contact"])
        XCTAssertEqual(repairedContacts.first?.email, "historical@example.com")
        XCTAssertEqual(repairedContacts.first?.phone, "5551112222")
    }

    func testRemoteOnlyActualLegacySessionFormatProvidesOrganizationContacts() throws {
        let root = try makeTempStorageRoot()
        let organizationID = UUID()
        let store = LocalStore(testStorageRootURL: root)

        try writeLegacySessionMetadata(
            root: root,
            propertyID: UUID(),
            sessionID: UUID(),
            values: [
                "orgID": organizationID.uuidString,
                "orgId": organizationID.uuidString,
                "orgName": "DJS Capital LLC",
                "orgNameAtCapture": "DJS Capital LLC",
                "primaryContactEmail": "djscapitallc@gmail.com",
                "primaryContactEmailAtCapture": "djscapitallc@gmail.com",
                "primaryContactName": "Devin Seilhamer",
                "primaryContactNameAtCapture": "Devin Seilhamer",
                "primaryContactPhone": "6144069619"
            ]
        )

        let contacts = try store.organizationContacts(
            organizationID: organizationID,
            organizationName: "DJS Capital LLC"
        )

        XCTAssertEqual(contacts.map(\.name), ["Devin Seilhamer"])
        XCTAssertEqual(contacts.first?.email, "djscapitallc@gmail.com")
        XCTAssertEqual(contacts.first?.phone, "6144069619")
    }

    func testRemoteOnlyLegacySessionAliasesCanDeriveOrganizationContacts() throws {
        let root = try makeTempStorageRoot()
        let organizationID = UUID()
        let store = LocalStore(testStorageRootURL: root)

        try writeLegacySessionMetadata(
            root: root,
            propertyID: UUID(),
            sessionID: UUID(),
            values: [
                "orgID": organizationID.uuidString,
                "orgName": "Remote Legacy Org",
                "contactName": "Alias Contact",
                "clientEmail": "alias@example.com",
                "clientPhone": "5553334444"
            ]
        )

        let contacts = try store.legacySessionContacts(
            organizationID: organizationID,
            organizationName: "Remote Legacy Org"
        )

        XCTAssertEqual(contacts.map(\.name), ["Alias Contact"])
        XCTAssertEqual(contacts.first?.email, "alias@example.com")
        XCTAssertEqual(contacts.first?.phone, "5553334444")
    }

    private func contacts(in organizations: [Organization], organizationID: UUID) -> [OrganizationContact] {
        organizations.first(where: { $0.id == organizationID })?.contacts ?? []
    }

    private func writeLegacySessionMetadata(
        root: URL,
        propertyID: UUID,
        sessionID: UUID,
        values: [String: String]
    ) throws {
        var payload = values
        payload["propertyID"] = propertyID.uuidString
        payload["sessionID"] = sessionID.uuidString

        let sessionURL = root
            .appendingPathComponent("SCOUT", isDirectory: true)
            .appendingPathComponent("Properties", isDirectory: true)
            .appendingPathComponent(propertyID.uuidString, isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: sessionURL.appendingPathComponent("session.json", isDirectory: false), options: .atomic)
    }
}

private struct LegacyHubIndexFixture: Encodable {
    let schemaVersion = 1
    let generatedAt: Date
    let properties: [LegacyPropertyRow]
    let organizations: [LegacyOrganizationRow]
}

private struct LegacyPropertyRow: Encodable {
    let id: UUID
    let orgId: UUID?
    let folderId: String?
    let clientName: String?
    let clientPhone: String?
    let clientEmail: String?
    let name: String
    let address: String? = nil
    let street: String? = nil
    let city: String? = nil
    let state: String? = nil
    let zip: String? = nil
    let baselineSessionID: UUID? = nil
    let isArchived = false
    let deletedAt: Date? = nil
    let createdAt: Date
    let updatedAt: Date
}

private struct LegacyOrganizationRow: Encodable {
    let id: UUID
    let name: String
}
