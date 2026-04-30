import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C12B4BHubForegroundAccessRefreshTests: XCTestCase {
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let localStore: LocalStore
        let appState: AppState
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C12B4BHubForegroundAccessRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C12B4B-\(UUID().uuidString)", isDirectory: true)
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

    func testForegroundHubRefreshAppliesPropertyToZero() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let property = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Visible")

        await configureAuthenticatedContext(fixture.appState, orgID: orgID, accessScope: "property")
        fixture.appState._debugSetAuthorizedPropertyIDsForTests(
            orgID: orgID,
            propertyIDs: Set([property.id])
        )

        XCTAssertEqual(fixture.appState.properties.map(\.id), [property.id])

        await fixture.appState._debugPerformForegroundAccessRefreshSequenceForTests(
            contextRefreshOverride: { _ in },
            propertyRefreshOverride: { _ in
                fixture.appState._debugSetAuthorizedPropertyIDsForTests(
                    orgID: orgID,
                    propertyIDs: Set<UUID>()
                )
                return true
            },
            convergenceOverride: { _ in }
        )

        XCTAssertTrue(fixture.appState.properties.isEmpty)
        XCTAssertEqual(fixture.appState.activeOrganizationID, orgID)
    }

    func testForegroundHubRefreshAppliesZeroToOrg() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let firstProperty = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "One")
        let secondProperty = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Two")

        await configureAuthenticatedContext(fixture.appState, orgID: orgID, accessScope: "property")
        fixture.appState._debugSetAuthorizedPropertyIDsForTests(
            orgID: orgID,
            propertyIDs: Set<UUID>()
        )

        XCTAssertTrue(fixture.appState.properties.isEmpty)

        await fixture.appState._debugPerformForegroundAccessRefreshSequenceForTests(
            contextRefreshOverride: { _ in
                fixture.appState._debugSetOrganizationContextForTests(
                    memberships: [
                        ActiveOrganizationMembership(id: orgID, name: "Org", role: "viewer", accessScope: "org")
                    ],
                    activeOrganizationID: orgID,
                    ready: true
                )
            },
            propertyRefreshOverride: { _ in true },
            convergenceOverride: { _ in }
        )

        XCTAssertEqual(
            Set(fixture.appState.properties.map(\.id)),
            Set([firstProperty.id, secondProperty.id])
        )
        XCTAssertEqual(fixture.appState.activeOrganizationMembershipAccessScope, "org")
    }

    func testForegroundOrgMembershipRevokeClearsVisiblePropertiesAndSkipsPropertyRefresh() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        _ = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "RevokedOrg")

        await configureAuthenticatedContext(fixture.appState, orgID: orgID, accessScope: "org")
        XCTAssertFalse(fixture.appState.properties.isEmpty)

        var propertyRefreshCallCount = 0

        await fixture.appState._debugPerformForegroundAccessRefreshSequenceForTests(
            contextRefreshOverride: { _ in
                fixture.appState._debugSetOrganizationContextForTests(
                    memberships: [],
                    activeOrganizationID: nil,
                    ready: true
                )
            },
            propertyRefreshOverride: { _ in
                propertyRefreshCallCount += 1
                return true
            },
            convergenceOverride: { _ in }
        )

        XCTAssertEqual(propertyRefreshCallCount, 0)
        XCTAssertNil(fixture.appState.activeOrganizationID)
        XCTAssertTrue(fixture.appState.properties.isEmpty)
        XCTAssertTrue(fixture.appState.accessibleOrganizations.isEmpty)
    }

    func testFailedForegroundRefreshDoesNotClearVisibleState() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let property = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Retained")

        await configureAuthenticatedContext(fixture.appState, orgID: orgID, accessScope: "property")
        fixture.appState._debugSetAuthorizedPropertyIDsForTests(
            orgID: orgID,
            propertyIDs: Set([property.id])
        )

        let originalVisiblePropertyIDs = fixture.appState.properties.map(\.id)
        var convergenceCallCount = 0

        await fixture.appState._debugPerformForegroundAccessRefreshSequenceForTests(
            contextRefreshOverride: { _ in },
            propertyRefreshOverride: { _ in false },
            convergenceOverride: { _ in
                convergenceCallCount += 1
            }
        )

        XCTAssertEqual(fixture.appState.properties.map(\.id), originalVisiblePropertyIDs)
        XCTAssertEqual(convergenceCallCount, 0)
    }

    func testActiveDraftSessionStillExitsOnlyOnConfirmedAccessLoss() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let property = try seedProperty(localStore: fixture.localStore, orgID: orgID, name: "Draft")

        await configureAuthenticatedContext(fixture.appState, orgID: orgID, accessScope: "property")
        fixture.appState._debugSetAuthorizedPropertyIDsForTests(
            orgID: orgID,
            propertyIDs: Set([property.id])
        )
        fixture.appState.selectProperty(id: property.id)
        _ = fixture.appState.startSession()

        await fixture.appState._debugPerformForegroundAccessRefreshSequenceForTests(
            contextRefreshOverride: { _ in },
            propertyRefreshOverride: { _ in false },
            convergenceOverride: { _ in }
        )

        XCTAssertNil(fixture.appState.activeSessionAccessRevocationRequest)
        XCTAssertEqual(fixture.appState.currentSession?.propertyID, property.id)

        await fixture.appState._debugPerformForegroundAccessRefreshSequenceForTests(
            contextRefreshOverride: { _ in },
            propertyRefreshOverride: { trigger in
                XCTAssertEqual(trigger, "foreground")
                fixture.appState._debugSetAuthorizedPropertyIDsForTests(
                    orgID: orgID,
                    propertyIDs: Set<UUID>()
                )
                return await fixture.appState._debugRunForegroundActiveSessionAccessCheckpointForTests(
                    refreshSucceeded: true,
                    authorizedPropertyIDs: [],
                    organizationID: orgID,
                    trigger: trigger ?? "foreground"
                )
            },
            convergenceOverride: { _ in }
        )

        XCTAssertEqual(
            fixture.appState.activeSessionAccessRevocationRequest?.message,
            "Access to this property was revoked."
        )
    }
}
