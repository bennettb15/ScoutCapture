import XCTest
@testable import ScoutCapture

final class Phase2C14B4SessionRemoteSoftDeleteTests: XCTestCase {
    private struct Fixture {
        let defaultsSuiteName: String
        let storageRoot: URL
        let defaults: UserDefaults
        let localStore: LocalStore
        let appState: AppState
        let orgID: UUID
        let propertyID: UUID
        let deviceID: String
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C14B4SessionRemoteSoftDeleteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        let deviceID = "phase2c14b4-device-\(UUID().uuidString)"
        defaults.set(deviceID, forKey: "scoutcapture.deviceIdentifier.v1")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C14B4-\(UUID().uuidString)", isDirectory: true)
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
                name: "Remote Session Delete Property",
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
            propertyID: propertyID,
            deviceID: deviceID
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

    private func seedSession(
        _ fixture: Fixture,
        id: UUID = UUID(),
        status: Session.Status = .completed
    ) throws -> Session {
        try fixture.localStore.upsertSession(
            Session(
                id: id,
                propertyID: fixture.propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: status,
                endedAt: status == .completed ? Date(timeIntervalSinceReferenceDate: 200) : nil
            )
        )
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func testRemoteSuccessSoftDeletesAndHidesSessionWithoutHardDelete() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let session = try seedSession(fixture)
        _ = try fixture.localStore.createObservation(
            Observation(
                propertyID: fixture.propertyID,
                sessionID: session.id,
                statement: "Keep me"
            )
        )
        try fixture.localStore.saveGuidedShots(
            [
                GuidedShot(
                    title: "Keep guided",
                    skipSessionID: session.id
                )
            ],
            propertyID: fixture.propertyID
        )
        try fixture.localStore.ensureSessionFolders(propertyID: fixture.propertyID, sessionID: session.id)
        let rawFolderExistsBefore = FileManager.default.fileExists(
            atPath: fixture.storageRoot
                .appendingPathComponent("SCOUT", isDirectory: true)
                .path
        )
        await prepareRemoteContext(fixture)

        var rpcCalls: [UUID] = []
        await MainActor.run {
            fixture.appState._debugSetSessionSoftDeleteOverridesForTests(
                rpc: { rpcCalls.append($0) },
                refresh: { true },
                deletePreflightRefresh: { _, _, _ in .clear }
            )
        }

        let deleted = await fixture.appState.remoteSoftDeleteSession(
            propertyID: fixture.propertyID,
            sessionID: session.id
        )

        let normalSessions = await MainActor.run {
            fixture.appState.sessions(for: fixture.propertyID)
        }
        let rawSessions = try fixture.localStore.fetchSessionsForCacheBuild(propertyID: fixture.propertyID)
        let observations = try fixture.localStore.fetchObservations(propertyID: fixture.propertyID)
        let guided = try fixture.localStore.fetchGuidedShots(propertyID: fixture.propertyID)

        XCTAssertTrue(deleted)
        XCTAssertEqual(rpcCalls, [session.id])
        XCTAssertTrue(normalSessions.isEmpty)
        XCTAssertNotNil(rawSessions.first(where: { $0.id == session.id })?.deletedAt)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(guided.count, 1)
        XCTAssertTrue(rawFolderExistsBefore)
    }

    func testRemoteFailureLeavesSessionVisibleAndUnmutated() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let session = try seedSession(fixture)
        await prepareRemoteContext(fixture)
        await MainActor.run {
            fixture.appState._debugSetSessionSoftDeleteOverridesForTests(
                rpc: { _ in throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "RPC failed"]) },
                refresh: { true },
                deletePreflightRefresh: { _, _, _ in .clear }
            )
        }

        let deleted = await fixture.appState.remoteSoftDeleteSession(
            propertyID: fixture.propertyID,
            sessionID: session.id
        )

        let normalSessions = await MainActor.run {
            fixture.appState.sessions(for: fixture.propertyID)
        }
        let rawSessions = try fixture.localStore.fetchSessionsForCacheBuild(propertyID: fixture.propertyID)

        XCTAssertFalse(deleted)
        XCTAssertEqual(normalSessions.map(\.id), [session.id])
        XCTAssertNil(rawSessions.first(where: { $0.id == session.id })?.deletedAt)
    }

    func testCurrentActiveSessionBlocksBeforeRPC() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        await prepareRemoteContext(fixture)
        fixture.appState.selectedPropertyID = fixture.propertyID
        let session = await MainActor.run {
            fixture.appState.startSession()!
        }
        var rpcCount = 0
        await MainActor.run {
            fixture.appState._debugSetSessionSoftDeleteOverridesForTests(
                rpc: { _ in rpcCount += 1 },
                refresh: { true },
                deletePreflightRefresh: { _, _, _ in .clear }
            )
        }

        let deleted = await fixture.appState.remoteSoftDeleteSession(
            propertyID: fixture.propertyID,
            sessionID: session.id
        )

        XCTAssertFalse(deleted)
        XCTAssertEqual(rpcCount, 0)
        XCTAssertEqual(fixture.appState.lastSessionDeleteErrorMessage, "Exit the active session before deleting this session.")
    }

    func testRemoteLockBlocksBeforeRPC() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let session = try seedSession(fixture)
        await prepareRemoteContext(fixture)
        var rpcCount = 0
        await MainActor.run {
            fixture.appState._debugSetSessionSoftDeleteOverridesForTests(
                rpc: { _ in rpcCount += 1 },
                refresh: { true },
                deletePreflightRefresh: { _, _, _ in
                    AppState.SessionDeletePreflightSnapshot(
                        deletedAt: nil,
                        occupancyCount: 0,
                        lockCount: 1,
                        isBlocked: true,
                        blockedReason: "session_lock"
                    )
                }
            )
        }

        let deleted = await fixture.appState.remoteSoftDeleteSession(
            propertyID: fixture.propertyID,
            sessionID: session.id
        )

        XCTAssertFalse(deleted)
        XCTAssertEqual(rpcCount, 0)
        XCTAssertEqual(fixture.appState.lastSessionDeleteErrorMessage, "This session is currently in use and cannot be deleted.")
    }

    func testRecentSameDeviceRemoteLockBlocksBeforeRPC() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let session = try seedSession(fixture)
        await prepareRemoteContext(fixture)
        let userID = fixture.appState.authenticatedSupabaseUser!.id
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: session.id,
                orgID: fixture.orgID,
                propertyID: fixture.propertyID,
                lockedByUserID: userID,
                lockedByDeviceID: fixture.deviceID,
                lockedAt: iso8601(Date()),
                coordinationTier1Snapshot: nil,
                updatedAt: Date()
            )
        )
        var rpcCount = 0
        await MainActor.run {
            fixture.appState._debugSetSessionSoftDeleteOverridesForTests(
                rpc: { _ in rpcCount += 1 },
                refresh: { true }
            )
        }

        let deleted = await fixture.appState.remoteSoftDeleteSession(
            propertyID: fixture.propertyID,
            sessionID: session.id
        )

        XCTAssertFalse(deleted)
        XCTAssertEqual(rpcCount, 0)
        XCTAssertEqual(fixture.appState.lastSessionDeleteErrorMessage, "This session is currently in use and cannot be deleted.")
    }

    func testStaleSameDeviceRemoteLockClearsAndAllowsSoftDeleteWithoutCascade() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let session = try seedSession(fixture)
        _ = try fixture.localStore.createObservation(
            Observation(
                propertyID: fixture.propertyID,
                sessionID: session.id,
                statement: "Still retained"
            )
        )
        try fixture.localStore.saveGuidedShots(
            [
                GuidedShot(
                    title: "Still retained",
                    skipSessionID: session.id
                )
            ],
            propertyID: fixture.propertyID
        )
        await prepareRemoteContext(fixture)
        let userID = fixture.appState.authenticatedSupabaseUser!.id
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: session.id,
                orgID: fixture.orgID,
                propertyID: fixture.propertyID,
                lockedByUserID: userID,
                lockedByDeviceID: fixture.deviceID,
                lockedAt: iso8601(Date().addingTimeInterval(-31 * 60)),
                coordinationTier1Snapshot: nil,
                updatedAt: Date().addingTimeInterval(-31 * 60)
            )
        )
        var rpcCalls: [UUID] = []
        await MainActor.run {
            fixture.appState._debugSetSessionSoftDeleteOverridesForTests(
                rpc: { rpcCalls.append($0) },
                refresh: { true }
            )
        }

        let deleted = await fixture.appState.remoteSoftDeleteSession(
            propertyID: fixture.propertyID,
            sessionID: session.id
        )

        let remoteLock = fixture.appState._debugReadSessionCoordinationStateForTests(sessionID: session.id)
        let rawSessions = try fixture.localStore.fetchSessionsForCacheBuild(propertyID: fixture.propertyID)
        let observations = try fixture.localStore.fetchObservations(propertyID: fixture.propertyID)
        let guided = try fixture.localStore.fetchGuidedShots(propertyID: fixture.propertyID)

        XCTAssertTrue(deleted)
        XCTAssertEqual(rpcCalls, [session.id])
        XCTAssertNil(remoteLock.lockedByUserID)
        XCTAssertNil(remoteLock.lockedByDeviceID)
        XCTAssertNil(remoteLock.lockedAt)
        XCTAssertNotNil(rawSessions.first(where: { $0.id == session.id })?.deletedAt)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(guided.count, 1)
    }

    func testStaleOtherDeviceRemoteLockStillBlocksBeforeRPC() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let session = try seedSession(fixture)
        await prepareRemoteContext(fixture)
        let userID = fixture.appState.authenticatedSupabaseUser!.id
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: session.id,
                orgID: fixture.orgID,
                propertyID: fixture.propertyID,
                lockedByUserID: userID,
                lockedByDeviceID: "other-device",
                lockedAt: iso8601(Date().addingTimeInterval(-31 * 60)),
                coordinationTier1Snapshot: nil,
                updatedAt: Date().addingTimeInterval(-31 * 60)
            )
        )
        var rpcCount = 0
        await MainActor.run {
            fixture.appState._debugSetSessionSoftDeleteOverridesForTests(
                rpc: { _ in rpcCount += 1 },
                refresh: { true }
            )
        }

        let deleted = await fixture.appState.remoteSoftDeleteSession(
            propertyID: fixture.propertyID,
            sessionID: session.id
        )

        XCTAssertFalse(deleted)
        XCTAssertEqual(rpcCount, 0)
        XCTAssertEqual(fixture.appState.lastSessionDeleteErrorMessage, "This session is currently in use and cannot be deleted.")
    }

    func testFailedPreflightBlocksBeforeRPC() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }
        let session = try seedSession(fixture)
        await prepareRemoteContext(fixture)
        var rpcCount = 0
        await MainActor.run {
            fixture.appState._debugSetSessionSoftDeleteOverridesForTests(
                rpc: { _ in rpcCount += 1 },
                refresh: { true },
                deletePreflightRefresh: { _, _, _ in
                    throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "preflight failed"])
                }
            )
        }

        let deleted = await fixture.appState.remoteSoftDeleteSession(
            propertyID: fixture.propertyID,
            sessionID: session.id
        )

        XCTAssertFalse(deleted)
        XCTAssertEqual(rpcCount, 0)
        XCTAssertTrue(fixture.appState.lastSessionDeleteErrorMessage?.contains("Unable to confirm this session is safe to delete") == true)
    }
}
