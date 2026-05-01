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
                building: nil,
                elevation: nil,
                detailType: nil,
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
}
