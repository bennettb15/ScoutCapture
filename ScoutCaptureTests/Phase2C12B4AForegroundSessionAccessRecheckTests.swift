import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C12B4AForegroundSessionAccessRecheckTests: XCTestCase {
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let localStore: LocalStore
        let appState: AppState
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C12B4AForegroundSessionAccessRecheckTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C12B4A-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let appState = AppState(localStore: localStore, userDefaults: defaults)

        return Fixture(
            suiteName: suiteName,
            defaults: defaults,
            storageRoot: storageRoot,
            localStore: localStore,
            appState: appState
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private func seedProperty(
        localStore: LocalStore,
        orgID: UUID,
        name: String
    ) throws -> Property {
        _ = try localStore.createOrganization(Organization(id: orgID, name: "Org \(name)"))
        return try localStore.createProperty(
            Property(
                orgId: orgID,
                folderId: "folder-\(name.lowercased())",
                name: name,
                address: "123 \(name) Street"
            )
        )
    }

    private func configureAuthenticatedContext(
        _ appState: AppState,
        orgID: UUID,
        accessScope: String = "property"
    ) async {
        appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: orgID,
            ready: true,
            clientConfigured: true,
            authenticated: true,
            authenticationReady: true,
            authenticatedUserID: UUID()
        )
        appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "viewer", accessScope: accessScope)
            ],
            activeOrganizationID: orgID,
            ready: true
        )
        appState._debugRefreshPropertiesLocallyForTests()
    }

    func testSuccessfulRefreshWithAccessRetainedDoesNotExit() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let property = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Visible")

        await configureAuthenticatedContext(fixture.appState, orgID: orgID)

        fixture.appState.selectProperty(id: property.id)
        _ = fixture.appState.startSession()

        let didRevoke = await fixture.appState._debugRunForegroundActiveSessionAccessCheckpointForTests(
            refreshSucceeded: true,
            authorizedPropertyIDs: Set([property.id]),
            organizationID: orgID
        )

        XCTAssertFalse(didRevoke)
        XCTAssertEqual(fixture.appState.currentSession?.propertyID, property.id)
        XCTAssertNil(fixture.appState.activeSessionAccessRevocationRequest)
    }

    func testSuccessfulRefreshWithActivePropertyRemovedExitsSafely() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let property = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Revoked")

        await configureAuthenticatedContext(fixture.appState, orgID: orgID)

        fixture.appState.selectProperty(id: property.id)
        let sessionID = fixture.appState.startSession()!.id

        let didRevoke = await fixture.appState._debugRunForegroundActiveSessionAccessCheckpointForTests(
            refreshSucceeded: true,
            authorizedPropertyIDs: [],
            organizationID: orgID
        )

        XCTAssertTrue(didRevoke)
        XCTAssertEqual(
            fixture.appState.activeSessionAccessRevocationRequest?.message,
            "Access to this property was revoked."
        )
        XCTAssertEqual(
            fixture.appState.hubTransientStatusMessage,
            "Access to this property was revoked."
        )

        let persistedSessions = try fixture.localStore.fetchSessions(propertyID: property.id)
        let persistedFacts = persistedSessions.map { ($0.id, $0.status) }
        XCTAssertTrue(persistedFacts.contains(where: { $0.0 == sessionID && $0.1 == .draft }))

        if let request = fixture.appState.activeSessionAccessRevocationRequest {
            fixture.appState.finalizeActiveSessionAccessRevocationIfNeeded(
                requestID: request.id,
                propertyID: request.propertyID
            )
        }

        XCTAssertNil(fixture.appState.currentSession)
        XCTAssertNil(fixture.appState.selectedPropertyID)
    }

    func testFailedRefreshDoesNotExit() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let property = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Transient")

        await configureAuthenticatedContext(fixture.appState, orgID: orgID)

        fixture.appState.selectProperty(id: property.id)
        _ = fixture.appState.startSession()

        let didRevoke = await fixture.appState._debugRunForegroundActiveSessionAccessCheckpointForTests(
            refreshSucceeded: false,
            authorizedPropertyIDs: [],
            organizationID: orgID
        )

        XCTAssertFalse(didRevoke)
        XCTAssertEqual(fixture.appState.currentSession?.propertyID, property.id)
        XCTAssertNil(fixture.appState.activeSessionAccessRevocationRequest)
    }
}
