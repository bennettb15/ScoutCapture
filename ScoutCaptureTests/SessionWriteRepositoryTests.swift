import XCTest
@testable import ScoutCapture

@MainActor
private final class RecordingSessionWriter: SessionWriteRepository {
    private(set) var upserts: [SessionWriteRecord] = []

    func upsert(_ record: SessionWriteRecord) async throws { upserts.append(record) }
    func update(_ record: SessionWriteRecord, propertyID: UUID, organizationID: UUID) async throws {}
    func insert(_ record: SessionInsertRecord) async throws {}
    func updateCaptureProfile(
        sessionID: UUID,
        propertyID: UUID,
        organizationID: UUID,
        profile: String,
        updatedBy: UUID?
    ) async throws -> [SessionCaptureProfileWriteResult] { [] }
    func updateLifecycle(
        _ lifecycle: SessionLifecycleWrite,
        sessionID: UUID,
        propertyID: UUID,
        organizationID: UUID
    ) async throws -> [SessionLifecycleWriteResult] { [] }
    func softDelete(sessionID: UUID) async throws {}
    func restore(sessionID: UUID) async throws {}
}

@MainActor
private final class RecordingSessionParentPropertyWriter: PropertyWriteRepository {
    func insert(_ record: PropertyWriteRecord) async throws {}
    func upsert(_ record: PropertyWriteRecord) async throws {}
    func updateCaptureProfile(
        propertyID: UUID,
        organizationID: UUID,
        profile: String,
        updatedBy: UUID?,
        verify: Bool
    ) async throws -> [PropertyCaptureProfileWriteResult] { [] }
    func softDelete(propertyID: UUID) async throws {}
    func restore(propertyID: UUID) async throws {}
}

final class SessionWriteRepositoryTests: XCTestCase {
    @MainActor
    func testSessionCreationUsesInjectedWriterWithoutSupabaseClient() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionWriteRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "SessionWriteRepositoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")

        let organizationID = UUID()
        let localStore = LocalStore(testStorageRootURL: root)
        try localStore.createOrganization(Organization(id: organizationID, name: "Test Org"))
        let writer = RecordingSessionWriter()
        let appState = AppState(
            localStore: localStore,
            userDefaults: defaults,
            environment: [:],
            propertyWriteRepository: RecordingSessionParentPropertyWriter(),
            sessionWriteRepository: writer,
            disableCloudBackupForTests: true
        )
        defer { appState.shutdown() }
        appState._debugSetOrganizationContextForTests(
            memberships: [ActiveOrganizationMembership(id: organizationID, name: "Test Org", role: "owner")],
            activeOrganizationID: organizationID,
            ready: true
        )
        let property = try appState.createProperty(
            organizationID: organizationID,
            clientName: "Client",
            propertyName: "Session Property",
            address: "123 Main Street"
        )
        appState._debugRefreshPropertiesLocallyForTests()
        appState.selectProperty(id: property.id)
        let started = try XCTUnwrap(appState.startSession(skipPropertyStatusPreflight: true))
        _ = appState.persistCurrentSessionType(.fullDocumentation)

        var record: SessionWriteRecord?
        for _ in 0..<100 {
            record = writer.upserts.first(where: { $0.id == started.id })
            if record != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let received = try XCTUnwrap(record)
        XCTAssertEqual(received.organizationID, organizationID)
        XCTAssertEqual(received.propertyID, property.id)
        XCTAssertEqual(received.title, "Session Property")
    }
}
