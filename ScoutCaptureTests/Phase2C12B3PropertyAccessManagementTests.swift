import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C12B3PropertyAccessManagementTests: XCTestCase {
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let appState: AppState
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C12B3PropertyAccessManagementTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C12B3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let appState = AppState(
            localStore: LocalStore(testStorageRootURL: storageRoot),
            userDefaults: defaults
        )

        return Fixture(
            suiteName: suiteName,
            defaults: defaults,
            storageRoot: storageRoot,
            appState: appState
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private func configureAuthenticatedContext(
        _ appState: AppState,
        memberships: [ActiveOrganizationMembership],
        activeOrganizationID: UUID?,
        authenticatedUserID: UUID = UUID()
    ) async {
        await MainActor.run {
            appState._debugSetOfflineReplayEnvironmentForTests(
                activeOrganizationID: activeOrganizationID,
                ready: true,
                clientConfigured: true,
                authenticated: true,
                authenticationReady: true,
                authenticatedUserID: authenticatedUserID
            )
            appState._debugSetOrganizationContextForTests(
                memberships: memberships,
                activeOrganizationID: activeOrganizationID,
                ready: true
            )
        }
    }

    func testOwnerGateControlsPropertyManagementAvailability() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "owner", accessScope: "org")
            ],
            activeOrganizationID: orgID
        )
        let ownerCanManage = await MainActor.run { fixture.appState.canManageActiveOrganizationAccess }
        XCTAssertTrue(ownerCanManage)

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "viewer", accessScope: "org")
            ],
            activeOrganizationID: orgID
        )
        let viewerCanManage = await MainActor.run { fixture.appState.canManageActiveOrganizationAccess }
        XCTAssertFalse(viewerCanManage)
    }

    func testSavingFullOrgAccessSetsOrgScope() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let memberID = UUID()
        var recordedScopes: [String] = []

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "owner", accessScope: "org")
            ],
            activeOrganizationID: orgID
        )

        fixture.appState._debugSetPropertyAccessMethodOverridesForTests(
            fetch: { _, _ in [] },
            setScope: { _, _, accessScope in
                recordedScopes.append(accessScope)
            }
        )

        try await fixture.appState.savePropertyAccessConfiguration(
            userID: memberID,
            orgID: orgID,
            accessScope: "org",
            grantedPropertyIDs: []
        )

        XCTAssertEqual(recordedScopes, ["org"])
    }

    func testSavingSelectedPropertiesSetsPropertyScope() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let memberID = UUID()
        let propertyID = UUID()
        var recordedScopes: [String] = []
        var granted: [UUID] = []

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "owner", accessScope: "org")
            ],
            activeOrganizationID: orgID
        )

        fixture.appState._debugSetPropertyAccessMethodOverridesForTests(
            fetch: { _, _ in [] },
            setScope: { _, _, accessScope in
                recordedScopes.append(accessScope)
            },
            grant: { _, _, propertyID in
                granted.append(propertyID)
            }
        )

        try await fixture.appState.savePropertyAccessConfiguration(
            userID: memberID,
            orgID: orgID,
            accessScope: "property",
            grantedPropertyIDs: Set([propertyID])
        )

        XCTAssertEqual(recordedScopes, ["property"])
        XCTAssertEqual(granted, [propertyID])
    }

    func testGrantListSaveCreatesAndRevokesExpectedDiff() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let memberID = UUID()
        let keepPropertyID = UUID()
        let revokePropertyID = UUID()
        let addPropertyID = UUID()
        var granted: [UUID] = []
        var revoked: [UUID] = []

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "owner", accessScope: "org")
            ],
            activeOrganizationID: orgID
        )

        fixture.appState._debugSetPropertyAccessMethodOverridesForTests(
            fetch: { _, _ in Set([keepPropertyID, revokePropertyID]) },
            setScope: { _, _, _ in },
            grant: { _, _, propertyID in
                granted.append(propertyID)
            },
            revoke: { _, _, propertyID in
                revoked.append(propertyID)
            }
        )

        try await fixture.appState.savePropertyAccessConfiguration(
            userID: memberID,
            orgID: orgID,
            accessScope: "property",
            grantedPropertyIDs: Set([keepPropertyID, addPropertyID])
        )

        XCTAssertEqual(granted, [addPropertyID])
        XCTAssertEqual(revoked, [revokePropertyID])
    }

    func testZeroSelectedPropertiesRemainsValid() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let memberID = UUID()
        let existingPropertyID = UUID()
        var revoked: [UUID] = []

        await configureAuthenticatedContext(
            fixture.appState,
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Org", role: "owner", accessScope: "org")
            ],
            activeOrganizationID: orgID
        )

        fixture.appState._debugSetPropertyAccessMethodOverridesForTests(
            fetch: { _, _ in Set([existingPropertyID]) },
            setScope: { _, _, _ in },
            revoke: { _, _, propertyID in
                revoked.append(propertyID)
            }
        )

        try await fixture.appState.savePropertyAccessConfiguration(
            userID: memberID,
            orgID: orgID,
            accessScope: "property",
            grantedPropertyIDs: []
        )

        XCTAssertEqual(revoked, [existingPropertyID])
    }
}
