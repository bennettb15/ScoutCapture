import XCTest
@testable import ScoutCapture

final class Phase2C12AOrgAccessControlTests: XCTestCase {
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let localStore: LocalStore
        let appState: AppState
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C12AOrgAccessControlTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C12A-\(UUID().uuidString)", isDirectory: true)
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
        memberships: [ActiveOrganizationMembership],
        activeOrganizationID: UUID?
    ) async {
        await MainActor.run {
            appState._debugSetOfflineReplayEnvironmentForTests(
                activeOrganizationID: activeOrganizationID,
                ready: true,
                clientConfigured: true,
                authenticated: true,
                authenticationReady: true,
                authenticatedUserID: UUID()
            )
            appState._debugSetOrganizationContextForTests(
                memberships: memberships,
                activeOrganizationID: activeOrganizationID,
                ready: true
            )
            appState._debugRefreshPropertiesLocallyForTests()
        }
    }

    func testOrganizationSelectionOptionsRemainDedupedByID() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Alpha Org", role: "owner"),
                ActiveOrganizationMembership(id: orgID, name: "Alpha Org Duplicate", role: "owner")
            ],
            activeOrganizationID: orgID
        )

        let options = await MainActor.run { fixture.appState.organizationSelectionOptions }
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.id, orgID)
    }

    func testRevokedActiveOrgFallsBackToRemainingAccessibleOrg() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgOneID = UUID()
        let orgTwoID = UUID()
        let propertyOne = try seedProperty(localStore: fixture.localStore, orgID: orgOneID, name: "One")
        let propertyTwo = try seedProperty(localStore: fixture.localStore, orgID: orgTwoID, name: "Two")

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgOneID, name: "Org One", role: "owner"),
                ActiveOrganizationMembership(id: orgTwoID, name: "Org Two", role: "viewer")
            ],
            activeOrganizationID: orgOneID
        )

        let initialPropertyIDs = await MainActor.run { Set(fixture.appState.properties.map(\.id)) }
        XCTAssertEqual(initialPropertyIDs, Set([propertyOne.id]))

        await MainActor.run {
            fixture.appState._debugSetOrganizationContextForTests(
                memberships: [
                    ActiveOrganizationMembership(id: orgTwoID, name: "Org Two", role: "viewer")
                ],
                activeOrganizationID: orgTwoID,
                ready: true
            )
        }

        let activeOrganizationID = await MainActor.run { fixture.appState.activeOrganizationID }
        let visiblePropertyIDs = await MainActor.run { Set(fixture.appState.properties.map(\.id)) }
        let visibleOrganizationIDs = await MainActor.run { Set(fixture.appState.organizationSelectionOptions.map(\.id)) }

        XCTAssertEqual(activeOrganizationID, orgTwoID)
        XCTAssertEqual(visiblePropertyIDs, Set([propertyTwo.id]))
        XCTAssertEqual(visibleOrganizationIDs, Set([orgTwoID]))
    }

    func testRevokedUserWithNoRemainingOrgShowsNoVisibleProperties() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        _ = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Solo")

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Solo Org", role: "viewer")
            ],
            activeOrganizationID: orgID
        )

        await MainActor.run {
            fixture.appState._debugSetOrganizationContextForTests(
                memberships: [],
                activeOrganizationID: nil,
                ready: true
            )
        }

        let activeOrganizationID = await MainActor.run { fixture.appState.activeOrganizationID }
        let visibleProperties = await MainActor.run { fixture.appState.properties }
        let visibleOrganizations = await MainActor.run { fixture.appState.organizations }

        XCTAssertNil(activeOrganizationID)
        XCTAssertTrue(visibleProperties.isEmpty)
        XCTAssertTrue(visibleOrganizations.isEmpty)
    }
}
