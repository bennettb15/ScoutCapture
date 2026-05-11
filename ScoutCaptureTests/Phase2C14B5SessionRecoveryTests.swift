import XCTest
@testable import ScoutCapture

final class Phase2C14B5SessionRecoveryTests: XCTestCase {
    private struct Fixture {
        let defaultsSuiteName: String
        let storageRoot: URL
        let defaults: UserDefaults
        let localStore: LocalStore
        let appState: AppState
        let orgID: UUID
        let propertyID: UUID
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C14B5SessionRecoveryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C14B5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let orgID = UUID()
        let propertyID = UUID()
        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let appState = AppState(localStore: localStore, userDefaults: defaults)
        _ = try localStore.createOrganization(Organization(id: orgID, name: "Org"))
        _ = try localStore.createProperty(
            Property(
                id: propertyID,
                orgId: orgID,
                folderId: "00001",
                name: "Recovery Property",
                address: "123 Main Street",
                street: "123 Main Street",
                city: "Atlanta",
                state: "GA",
                zip: "30301"
            )
        )

        return Fixture(
            defaultsSuiteName: suiteName,
            storageRoot: storageRoot,
            defaults: defaults,
            localStore: localStore,
            appState: appState,
            orgID: orgID,
            propertyID: propertyID
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    @MainActor
    private func prepareRemoteContext(_ fixture: Fixture) {
        fixture.appState.refreshProperties()
        fixture.appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(
                    id: fixture.orgID,
                    name: "Org",
                    role: "owner"
                )
            ],
            activeOrganizationID: fixture.orgID,
            ready: true
        )
        fixture.appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: fixture.orgID,
            authenticated: true
        )
    }

    private func recentlyDeletedSession(
        _ fixture: Fixture,
        id: UUID = UUID()
    ) -> AppState.RecentlyDeletedSession {
        AppState.RecentlyDeletedSession(
            id: id,
            orgID: fixture.orgID,
            propertyID: fixture.propertyID,
            status: Session.Status.completed.rawValue,
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            endedAt: Date(timeIntervalSinceReferenceDate: 200),
            exportedAt: Date(timeIntervalSinceReferenceDate: 300),
            isSealed: true,
            firstDeliveredAt: Date(timeIntervalSinceReferenceDate: 400),
            reExportExpiresAt: Date(timeIntervalSinceReferenceDate: 500),
            notes: "Preserve notes",
            deletedAt: Date(timeIntervalSinceReferenceDate: 600),
            updatedAt: Date(timeIntervalSinceReferenceDate: 700),
            updatedBy: UUID(),
            revision: 3
        )
    }

    func testRecentlyDeletedSessionsFetchUsesRPC() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        await prepareRemoteContext(fixture)
        let deleted = recentlyDeletedSession(fixture)
        var requestedOrgID: UUID?
        var requestedPropertyID: UUID?
        await MainActor.run {
            fixture.appState._debugSetSessionSoftDeleteOverridesForTests(
                recentlyDeletedFetch: { orgID, propertyID in
                    requestedOrgID = orgID
                    requestedPropertyID = propertyID
                    return [deleted]
                }
            )
        }

        let fetched = try await fixture.appState.fetchRecentlyDeletedSessionsRemote()

        XCTAssertEqual(fetched, [deleted])
        XCTAssertEqual(requestedOrgID, fixture.orgID)
        XCTAssertNil(requestedPropertyID)
    }

    func testRestoreCallsRPCAndReturnsSessionToNormalLists() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        await prepareRemoteContext(fixture)
        let deleted = recentlyDeletedSession(fixture)
        _ = try fixture.localStore.upsertSession(
            Session(
                id: deleted.id,
                propertyID: deleted.propertyID,
                startedAt: deleted.startedAt,
                status: .completed,
                endedAt: deleted.endedAt,
                exportedAt: deleted.exportedAt,
                isSealed: deleted.isSealed,
                firstDeliveredAt: deleted.firstDeliveredAt,
                reExportExpiresAt: deleted.reExportExpiresAt,
                notes: deleted.notes,
                deletedAt: deleted.deletedAt
            )
        )
        fixture.appState.refreshProperties()
        var restoredIDs: [UUID] = []
        await MainActor.run {
            fixture.appState._debugSetSessionSoftDeleteOverridesForTests(
                restore: { restoredIDs.append($0) },
                restoreRefresh: { true }
            )
        }

        let restored = await fixture.appState.remoteRestoreSession(deleted)
        let normalSessions = await MainActor.run {
            fixture.appState.sessions(for: fixture.propertyID)
        }
        let rawSession = try fixture.localStore.fetchSessionsForCacheBuild(propertyID: fixture.propertyID)
            .first(where: { $0.id == deleted.id })

        XCTAssertTrue(restored)
        XCTAssertEqual(restoredIDs, [deleted.id])
        XCTAssertEqual(normalSessions.map(\.id), [deleted.id])
        XCTAssertNil(rawSession?.deletedAt)
        XCTAssertEqual(rawSession?.exportedAt, deleted.exportedAt)
        XCTAssertEqual(rawSession?.isSealed, deleted.isSealed)
        XCTAssertEqual(rawSession?.firstDeliveredAt, deleted.firstDeliveredAt)
        XCTAssertEqual(rawSession?.reExportExpiresAt, deleted.reExportExpiresAt)
        XCTAssertEqual(rawSession?.notes, deleted.notes)
    }

    func testRestoreFailureLeavesDeletedStateUnchanged() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        await prepareRemoteContext(fixture)
        let deleted = recentlyDeletedSession(fixture)
        _ = try fixture.localStore.upsertSession(
            Session(
                id: deleted.id,
                propertyID: deleted.propertyID,
                startedAt: deleted.startedAt,
                status: .completed,
                deletedAt: deleted.deletedAt
            )
        )
        fixture.appState.refreshProperties()
        await MainActor.run {
            fixture.appState._debugSetSessionSoftDeleteOverridesForTests(
                restore: { _ in
                    throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "restore failed"])
                },
                restoreRefresh: { true }
            )
        }

        let restored = await fixture.appState.remoteRestoreSession(deleted)
        let normalSessions = await MainActor.run {
            fixture.appState.sessions(for: fixture.propertyID)
        }
        let rawSession = try fixture.localStore.fetchSessionsForCacheBuild(propertyID: fixture.propertyID)
            .first(where: { $0.id == deleted.id })

        XCTAssertFalse(restored)
        XCTAssertTrue(normalSessions.isEmpty)
        XCTAssertEqual(rawSession?.deletedAt, deleted.deletedAt)
    }
}
