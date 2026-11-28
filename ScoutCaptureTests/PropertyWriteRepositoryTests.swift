import XCTest
@testable import ScoutCapture

@MainActor
private final class RecordingPropertyWriter: PropertyWriteRepository {
    private(set) var upserts: [PropertyWriteRecord] = []

    func insert(_ record: PropertyWriteRecord) async throws {
        upserts.append(record)
    }

    func upsert(_ record: PropertyWriteRecord) async throws {
        upserts.append(record)
    }

    func updateCaptureProfile(
        propertyID: UUID,
        organizationID: UUID,
        profile: String,
        updatedBy: UUID?,
        verify: Bool
    ) async throws -> [PropertyCaptureProfileWriteResult] {
        []
    }

    func softDelete(propertyID: UUID) async throws {}
    func restore(propertyID: UUID) async throws {}
}

final class PropertyWriteRepositoryTests: XCTestCase {
    @MainActor
    func testLocalCreateEditAndArchiveUseInjectedPropertyWriter() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PropertyWriteRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PropertyWriteRepositoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")

        let organizationID = UUID()
        let localStore = LocalStore(testStorageRootURL: root)
        try localStore.createOrganization(Organization(id: organizationID, name: "Test Org"))
        let writer = RecordingPropertyWriter()
        let appState = AppState(
            localStore: localStore,
            userDefaults: defaults,
            environment: [:],
            propertyWriteRepository: writer,
            disableCloudBackupForTests: true
        )
        defer { appState.shutdown() }
        appState._debugSetOrganizationContextForTests(
            memberships: [ActiveOrganizationMembership(id: organizationID, name: "Test Org", role: "owner")],
            activeOrganizationID: organizationID,
            ready: true
        )

        let created = try appState.createProperty(
            organizationID: organizationID,
            clientName: "Client",
            propertyName: "Original",
            address: "123 Main Street"
        )
        let createRecord = try await waitForRecord(writer) { $0.id == created.id && $0.name == "Original" }
        XCTAssertEqual(createRecord.organizationID, organizationID)
        XCTAssertEqual(createRecord.clientName, "Client")

        XCTAssertTrue(appState.updatePropertyContact(
            id: created.id,
            organizationID: organizationID,
            propertyName: "Edited",
            clientName: "Updated Client",
            address: "456 Oak Street",
            street: "456 Oak Street",
            city: "Austin",
            state: "TX",
            zip: "78701",
            clientPhone: "555-123-4567",
            clientEmail: "client@example.com"
        ))
        let editRecord = try await waitForRecord(writer) { $0.id == created.id && $0.name == "Edited" }
        XCTAssertEqual(editRecord.clientPhone, "5551234567")
        XCTAssertEqual(editRecord.city, "Austin")

        XCTAssertTrue(appState.setPropertyArchived(id: created.id, archived: true))
        let archiveRecord = try await waitForRecord(writer) { $0.id == created.id && $0.isArchived }
        XCTAssertEqual(archiveRecord.name, "Edited")
    }

    @MainActor
    private func waitForRecord(
        _ writer: RecordingPropertyWriter,
        matching predicate: (PropertyWriteRecord) -> Bool
    ) async throws -> PropertyWriteRecord {
        for _ in 0..<100 {
            if let record = writer.upserts.first(where: predicate) { return record }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "PropertyWriteRepositoryTests", code: 1)
    }
}
