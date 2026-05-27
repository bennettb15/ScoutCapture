import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C27FECanonicalOrgPersistenceTests: XCTestCase {
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let root: URL
        let store: LocalStore
        let appState: AppState
        let legacyOrgID: UUID
        let canonicalOrgID: UUID
        let property: Property
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C27FECanonicalOrgPersistence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C27FE-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = LocalStore(testStorageRootURL: root)
        let legacyOrgID = UUID()
        let canonicalOrgID = UUID()
        _ = try store.createOrganization(Organization(id: legacyOrgID, name: "Legacy Local Org"))
        let property = try store.createProperty(
            Property(
                id: UUID(),
                orgId: legacyOrgID,
                folderId: "00001",
                name: "Five Below Stable Draft",
                address: "10701 Blacklick Eastern Rd"
            )
        )

        let appState = AppState(localStore: store, userDefaults: defaults, disableCloudBackupForTests: true)
        appState._debugRefreshPropertiesLocallyForTests()
        appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: canonicalOrgID,
            authenticatedUserID: UUID()
        )
        appState.selectProperty(id: property.id)

        return Fixture(
            suiteName: suiteName,
            defaults: defaults,
            root: root,
            store: store,
            appState: appState,
            legacyOrgID: legacyOrgID,
            canonicalOrgID: canonicalOrgID,
            property: property
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func rawPersistedProperties(in root: URL) throws -> [Property] {
        let url = root
            .appendingPathComponent("SCOUT", isDirectory: true)
            .appendingPathComponent("properties.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Property].self, from: Data(contentsOf: url))
    }

    func testNewPropertyAndSessionUseCanonicalOrgIDWhenAvailable() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let session = try XCTUnwrap(fixture.appState.startSession())
        let persistedProperty = try XCTUnwrap(try fixture.store.fetchProperties().first { $0.id == fixture.property.id })
        let metadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: session.id)

        XCTAssertEqual(persistedProperty.orgId, fixture.canonicalOrgID)
        XCTAssertEqual(metadata.orgID, fixture.canonicalOrgID)
        XCTAssertNotEqual(persistedProperty.orgId, fixture.legacyOrgID)
    }

    func testRepairedOrgDriftPersistsToRawLocalLedger() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        _ = try fixture.appState.startSession()

        let rawProperty = try XCTUnwrap(try rawPersistedProperties(in: fixture.root).first { $0.id == fixture.property.id })
        XCTAssertEqual(rawProperty.orgId, fixture.canonicalOrgID)
    }

    func testReentryDoesNotRevertToLegacyOrgID() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let first = try XCTUnwrap(fixture.appState.startSession())
        fixture.appState.clearCurrentSession()
        fixture.appState._debugRefreshPropertiesLocallyForTests()
        fixture.appState.selectProperty(id: fixture.property.id)
        let reopened = try XCTUnwrap(fixture.appState.startSession())

        let rawProperty = try XCTUnwrap(try rawPersistedProperties(in: fixture.root).first { $0.id == fixture.property.id })
        let metadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: reopened.id)

        XCTAssertEqual(reopened.id, first.id)
        XCTAssertEqual(rawProperty.orgId, fixture.canonicalOrgID)
        XCTAssertEqual(metadata.orgID, fixture.canonicalOrgID)
    }

    func testDraftSessionCreationUsesCanonicalOrgID() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let draft = try XCTUnwrap(fixture.appState.startSession())
        let metadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: draft.id)
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertEqual(draft.status, .draft)
        XCTAssertEqual(metadata.orgID, fixture.canonicalOrgID)
        XCTAssertEqual(diagnostics.lastOrgPersistenceCanonicalSupabaseOrgID, fixture.canonicalOrgID)
        XCTAssertEqual(diagnostics.lastOrgPersistenceMatch, true)
        XCTAssertTrue(diagnostics.lastOrgPersistenceRepairResult.contains("repaired_start_session"))
    }

    func testLegacyOrgMayRemainAsAliasButNotPrimaryPropertyOrg() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        _ = try fixture.appState.startSession()

        let organizations = try fixture.store.fetchOrganizations()
        let persistedProperty = try XCTUnwrap(try fixture.store.fetchProperties().first { $0.id == fixture.property.id })

        XCTAssertTrue(organizations.contains { $0.id == fixture.legacyOrgID })
        XCTAssertTrue(organizations.contains { $0.id == fixture.canonicalOrgID })
        XCTAssertEqual(persistedProperty.orgId, fixture.canonicalOrgID)
        XCTAssertNotEqual(persistedProperty.orgId, fixture.legacyOrgID)
    }
}
