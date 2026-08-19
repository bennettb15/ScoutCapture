import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C13B1BAuditEventEmitterTests: XCTestCase {
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let appState: AppState
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C13B1BAuditEventEmitterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C13B1B-\(UUID().uuidString)", isDirectory: true)
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
        orgID: UUID,
        authenticatedUserID: UUID = UUID()
    ) async {
        await MainActor.run {
            appState._debugSetOfflineReplayEnvironmentForTests(
                activeOrganizationID: orgID,
                ready: true,
                clientConfigured: true,
                authenticated: true,
                authenticationReady: true,
                authenticatedUserID: authenticatedUserID
            )
            appState._debugSetOrganizationContextForTests(
                memberships: [
                    ActiveOrganizationMembership(
                        id: orgID,
                        name: "Org",
                        role: "owner",
                        accessScope: "org"
                    )
                ],
                activeOrganizationID: orgID,
                ready: true
            )
        }
    }

    func testGrantEventEmittedAfterSuccessfulGrant() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let targetUserID = UUID()
        let propertyID = UUID()
        var emittedEventTypes: [String] = []

        await configureAuthenticatedContext(fixture.appState, orgID: orgID)

        fixture.appState._debugSetAuditEventEmitOverrideForTests { _, eventType, _, _, _ in
            emittedEventTypes.append(eventType)
        }
        fixture.appState._debugSetPropertyAccessMethodOverridesForTests(
            grant: { _, _, _ in }
        )

        try await fixture.appState.grantPropertyAccess(
            userID: targetUserID,
            orgID: orgID,
            propertyID: propertyID
        )

        XCTAssertEqual(emittedEventTypes, ["property.access.granted"])
    }

    func testNoGrantEventEmittedWhenSaveIsNoOp() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let targetUserID = UUID()
        let propertyID = UUID()
        var emittedEventTypes: [String] = []
        var grantCalls = 0

        await configureAuthenticatedContext(fixture.appState, orgID: orgID)

        fixture.appState._debugSetAuditEventEmitOverrideForTests { _, eventType, _, _, _ in
            emittedEventTypes.append(eventType)
        }
        fixture.appState._debugSetPropertyAccessMethodOverridesForTests(
            fetch: { _, _ in Set([propertyID]) },
            setScope: { _, _, _ in },
            grant: { _, _, _ in
                grantCalls += 1
            }
        )

        try await fixture.appState.savePropertyAccessConfiguration(
            userID: targetUserID,
            orgID: orgID,
            accessScope: "property",
            grantedPropertyIDs: Set([propertyID])
        )

        XCTAssertEqual(grantCalls, 0)
        XCTAssertEqual(emittedEventTypes, [])
    }

    func testRevokeEventEmittedAfterSuccessfulRevoke() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        let targetUserID = UUID()
        let propertyID = UUID()
        var emittedEventTypes: [String] = []

        await configureAuthenticatedContext(fixture.appState, orgID: orgID)

        fixture.appState._debugSetAuditEventEmitOverrideForTests { _, eventType, _, _, _ in
            emittedEventTypes.append(eventType)
        }
        fixture.appState._debugSetPropertyAccessMethodOverridesForTests(
            revoke: { _, _, _ in }
        )

        try await fixture.appState.revokePropertyAccess(
            userID: targetUserID,
            orgID: orgID,
            propertyID: propertyID
        )

        XCTAssertEqual(emittedEventTypes, ["property.access.revoked"])
    }

    func testEmitAuditEventDoesNotThrowOnInsertFailure() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let orgID = UUID()
        await configureAuthenticatedContext(fixture.appState, orgID: orgID)

        struct TestFailure: LocalizedError {
            var errorDescription: String? { "expected failure" }
        }

        fixture.appState._debugSetAuditEventEmitOverrideForTests { _, _, _, _, _ in
            throw TestFailure()
        }

        await fixture.appState.emitAuditEvent(
            orgID: orgID,
            eventType: "member.invited",
            payload: ["target_email": "test@example.com"]
        )
    }
}
