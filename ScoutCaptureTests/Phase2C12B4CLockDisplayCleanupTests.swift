import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C12B4CLockDisplayCleanupTests: XCTestCase {
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let localStore: LocalStore
        let appState: AppState
        let orgID: UUID
        let property: Property
        let draftSession: Session
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C12B4CLockDisplayCleanupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")
        defaults.set(true, forKey: "session_coordination_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C12B4C-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let orgID = UUID()
        let userID = UUID()
        _ = try localStore.createOrganization(Organization(id: orgID, name: "Test Org"))
        let property = try localStore.createProperty(
            Property(
                orgId: orgID,
                folderId: "lock-cleanup",
                name: "Lock Cleanup",
                address: "123 Cleanup Lane"
            )
        )

        let draftSession = try localStore.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .draft,
                endedAt: nil,
                exportedAt: nil,
                isSealed: false
            )
        )
        try localStore.ensureSessionMetadata(for: draftSession)
        var draftMetadata = try localStore.loadSessionMetadata(propertyID: property.id, sessionID: draftSession.id)
        draftMetadata.shots = [
            ShotMetadata(
                shotID: UUID(),
                propertyID: property.id,
                sessionID: draftSession.id,
                createdAt: Date(timeIntervalSinceReferenceDate: 101),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 101),
                building: "",
                elevation: "",
                detailType: "",
                angleIndex: 0,
                trade: nil,
                priority: nil,
                shotKey: "cleanup",
                isGuided: false,
                isFlagged: false,
                issueID: nil,
                issueStatus: nil,
                captureKind: nil,
                firstCaptureKind: nil,
                noteText: nil,
                noteCategory: nil,
                originalFilename: "draft.jpg",
                originalRelativePath: "originals/draft.jpg",
                originalByteSize: 1024,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                orientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        try localStore.saveSessionMetadataAtomically(propertyID: property.id, sessionID: draftSession.id, metadata: draftMetadata)

        let newerCompletedSession = try localStore.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 200),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 210),
                exportedAt: nil,
                isSealed: true
            )
        )
        try localStore.ensureSessionMetadata(for: newerCompletedSession)

        let appState = AppState(localStore: localStore, userDefaults: defaults, disableCloudBackupForTests: true)
        appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Test Org", role: "owner")
            ],
            activeOrganizationID: orgID,
            ready: true
        )
        appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: orgID,
            ready: true,
            clientConfigured: true,
            authenticated: true,
            authenticationReady: true,
            authenticatedUserID: userID
        )
        appState._debugRefreshPropertiesLocallyForTests()

        return Fixture(
            suiteName: suiteName,
            defaults: defaults,
            storageRoot: storageRoot,
            localStore: localStore,
            appState: appState,
            orgID: orgID,
            property: property,
            draftSession: draftSession
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func testClearLockDisplayStateRemovesStaleDraftSessionCoordinationState() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.draftSession.id,
            lockedByUserID: UUID(),
            lockedByDeviceID: "other-device",
            lockedAt: Date()
        )

        XCTAssertTrue(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))

        fixture.appState._debugClearLockDisplayStateForTests(propertyIDs: [fixture.property.id])

        XCTAssertFalse(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))
    }

    func testRemoteCompletedSessionClearsStaleDraftAndLockUIState() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.draftSession.id,
            lockedByUserID: UUID(),
            lockedByDeviceID: "other-device",
            lockedAt: Date()
        )

        let completedAt = Date(timeIntervalSinceReferenceDate: 500)
        let result = fixture.appState._debugApplySyncDeltaSessionsForTests(
            records: [
                AppState.DebugRemoteSessionDeltaInput(
                    id: fixture.draftSession.id,
                    orgID: fixture.orgID,
                    propertyID: fixture.property.id,
                    title: "Lock Cleanup",
                    status: Session.Status.completed.rawValue,
                    startedAt: iso8601(fixture.draftSession.startedAt),
                    completedAt: iso8601(completedAt),
                    exportedAt: completedAt,
                    isSealed: true,
                    firstDeliveredAt: completedAt,
                    reExportExpiresAt: nil,
                    updatedAt: Date(),
                    deletedAt: nil
                )
            ],
            orgID: fixture.orgID
        )

        XCTAssertEqual(result.applied, 1)
        XCTAssertNil(fixture.appState.draftSession(for: fixture.property.id))
        XCTAssertFalse(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))
        let persisted = fixture.appState.sessions(for: fixture.property.id).first { $0.id == fixture.draftSession.id }
        XCTAssertEqual(persisted?.status, .completed)
        XCTAssertTrue(persisted?.isSealed == true)
        XCTAssertEqual(persisted?.exportedAt, completedAt)
    }

    func testFinalSessionDiagnosticsSuppressDraftAndLockForSecondLogin() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let exportedAt = Date(timeIntervalSinceReferenceDate: 600)
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.draftSession.id,
                orgID: fixture.orgID,
                propertyID: fixture.property.id,
                lockedByUserID: UUID(),
                lockedByDeviceID: "other-device",
                lockedAt: iso8601(exportedAt),
                coordinationTier1Snapshot: nil,
                updatedAt: exportedAt,
                status: Session.Status.completed.rawValue,
                exportedAt: exportedAt,
                isSealed: true,
                firstDeliveredAt: exportedAt,
                reExportExpiresAt: nil
            )
        )
        _ = fixture.appState._debugApplySyncDeltaSessionsForTests(
            records: [
                AppState.DebugRemoteSessionDeltaInput(
                    id: fixture.draftSession.id,
                    orgID: fixture.orgID,
                    propertyID: fixture.property.id,
                    title: "Lock Cleanup",
                    status: Session.Status.completed.rawValue,
                    startedAt: iso8601(fixture.draftSession.startedAt),
                    completedAt: iso8601(exportedAt),
                    exportedAt: exportedAt,
                    isSealed: true,
                    firstDeliveredAt: exportedAt,
                    reExportExpiresAt: nil,
                    updatedAt: exportedAt,
                    deletedAt: nil
                )
            ],
            orgID: fixture.orgID
        )

        let diagnostics = fixture.appState.sessionUIStateDiagnostics(
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id
        )

        XCTAssertEqual(diagnostics?.computedShowsDraft, false)
        XCTAssertEqual(diagnostics?.computedShowsLock, false)
        XCTAssertEqual(diagnostics?.computedCanOpen, true)
        XCTAssertEqual(diagnostics?.reason, "final_session_suppresses_draft_and_lock")
    }

    func testActiveDraftLockAppearsOnlyWhileFresh() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.draftSession.id,
            lockedByUserID: UUID(),
            lockedByDeviceID: "other-device",
            lockedAt: Date()
        )

        XCTAssertTrue(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.draftSession.id,
            lockedByUserID: UUID(),
            lockedByDeviceID: "other-device",
            lockedAt: Date(timeIntervalSinceNow: -31 * 60)
        )

        XCTAssertFalse(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))
        let diagnostics = fixture.appState.sessionUIStateDiagnostics(
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id
        )
        XCTAssertEqual(diagnostics?.reason, "stale_lock_ignored")
    }
}
