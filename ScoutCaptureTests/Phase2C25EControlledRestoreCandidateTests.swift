import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C25EControlledRestoreCandidateTests: XCTestCase {
    private struct Fixture {
        var store: LocalStore
        var appState: AppState
        var property: Property
        var session: Session
        var orgID: UUID
        var row: AppState.SessionSnapshotUploadRow
        var object: AppState.SessionSnapshotStorageObject
    }

    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C25E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C25E-\(UUID().uuidString)") ?? .standard
        defaults.set(true, forKey: "session_snapshot_shadow_write_enabled")
        return defaults
    }

    private func localEnvironment() -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key"
        ]
    }

    private func productionValidationEnvironment() -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": "https://chlvazmtucoszicehtnm.supabase.co",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "production-validation-anon-key",
            "SCOUTCAPTURE_PRODUCTION_SNAPSHOT_VALIDATION_ALLOWED": "true"
        ]
    }

    private func makeFixture(generatedAt: Date = Date(timeIntervalSinceReferenceDate: 1_000)) throws -> Fixture {
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let orgID = UUID()
        _ = try store.createOrganization(Organization(id: orgID, name: "25E Restore Candidate Org"))
        let property = try store.createProperty(Property(id: UUID(), orgId: orgID, name: "25E Restore Candidate Property"))
        let session = try store.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                exportedAt: nil,
                isSealed: true,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil
            )
        )
        try saveMetadata(store: store, property: property, session: session, orgID: orgID)

        let artifactAppState = AppState(
            localStore: store,
            userDefaults: makeDefaults(),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in },
            sessionSnapshotRowInsertOverride: { _ in },
            disableCloudBackupForTests: true
        )
        let artifacts = try artifactAppState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: property.id,
            sessionID: session.id,
            generatedAt: generatedAt
        )
        let appState = AppState(
            localStore: store,
            userDefaults: makeDefaults(),
            environment: localEnvironment(),
            sessionSnapshotRowsFetchOverride: { _, _, _ in [artifacts.row] },
            sessionSnapshotStorageDownloadOverride: { _, _ in artifacts.object.payloadData },
            sessionSnapshotRemoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: orgID,
                    sessionOrgID: orgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: true,
                    errorMessage: nil
                )
            },
            disableCloudBackupForTests: true
        )
        appState.selectedPropertyID = property.id
        return Fixture(
            store: store,
            appState: appState,
            property: property,
            session: session,
            orgID: orgID,
            row: artifacts.row,
            object: artifacts.object
        )
    }

    private func saveMetadata(store: LocalStore, property: Property, session: Session, orgID: UUID) throws {
        let shotID = UUID()
        let issueID = UUID()
        let shot = ShotMetadata(
            shotID: shotID,
            propertyID: property.id,
            sessionID: session.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 120),
            updatedAt: Date(timeIntervalSinceReferenceDate: 130),
            building: "A",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            shotKey: "a-north-overview-1",
            isGuided: true,
            isFlagged: true,
            issueID: issueID,
            issueStatus: "active",
            noteText: "25E metadata hydration test",
            noteCategory: "general",
            originalFilename: "missing-original.jpg",
            originalRelativePath: "Originals/missing-original.jpg",
            originalByteSize: 123,
            storageBucket: "media",
            storagePath: "remote/media/path.jpg",
            checksumSHA256: String(repeating: "a", count: 64),
            byteSize: 123,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: nil,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )
        let issue = IssueMetadata(
            issueID: issueID,
            issueStatus: "active",
            currentReason: "Needs repair",
            firstSeenAt: Date(timeIntervalSinceReferenceDate: 120),
            lastSeenAt: Date(timeIntervalSinceReferenceDate: 130),
            lastCaptureSessionId: session.id,
            detailNote: "25E hydrated issue",
            shotKey: shot.shotKey
        )
        let guided = GuidedShot(
            title: "North overview",
            building: "A",
            targetElevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            referenceImagePath: "References/reference.jpg",
            shot: Shot(id: shotID, capturedAt: shot.createdAt),
            isCompleted: true
        )
        let metadata = SessionMetadata(
            schemaVersion: 12,
            propertyID: property.id,
            sessionID: session.id,
            orgID: orgID,
            propertyNameAtCapture: property.name,
            propertyNameAtExport: nil,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            status: session.status,
            isBaselineSession: false,
            exportedAt: session.exportedAt,
            isSealed: session.isSealed,
            firstDeliveredAt: session.firstDeliveredAt,
            reExportExpiresAt: session.reExportExpiresAt,
            appVersion: "test-app",
            deviceModel: "test-device",
            osVersion: "test-os",
            shots: [shot],
            issues: [issue],
            guidedShots: [guided]
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)
    }

    func testPositiveRestoreCandidateCanHydrateMetadata() async throws {
        let fixture = try makeFixture()
        try fixture.store.deleteSession(id: fixture.session.id, propertyID: fixture.property.id)

        let diagnostics = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()
        let hydration = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()
        let metadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)

        XCTAssertEqual(diagnostics.result, .restorableMetadataCandidate)
        XCTAssertTrue(diagnostics.checksumVerified)
        XCTAssertTrue(diagnostics.rowObjectVerified)
        XCTAssertTrue(diagnostics.parentRemoteVerified)
        XCTAssertNotEqual(diagnostics.result, .localNewerConflict)
        XCTAssertTrue(hydration.allowed)
        XCTAssertEqual(hydration.sourceSnapshotID, fixture.row.id)
        XCTAssertEqual(hydration.sessionID, fixture.session.id)
        XCTAssertEqual(hydration.hydratedShotCount, diagnostics.snapshotShotCount)
        XCTAssertEqual(hydration.hydratedIssueCount, diagnostics.snapshotIssueCount)
        XCTAssertEqual(hydration.hydratedGuidedCount, diagnostics.snapshotGuidedCount)
        XCTAssertEqual(metadata.shots.count, diagnostics.snapshotShotCount)
        XCTAssertEqual(metadata.issues.count, diagnostics.snapshotIssueCount)
        XCTAssertEqual(metadata.guidedShots.count, diagnostics.snapshotGuidedCount)
    }

    func testMissingLocalMetadataHydratesWithoutRestoringMedia() async throws {
        let fixture = try makeFixture()
        try fixture.store.deleteSession(id: fixture.session.id, propertyID: fixture.property.id)
        let mediaURL = fixture.store
            .sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id)
            .deletingLastPathComponent()
            .appendingPathComponent("Originals/missing-original.jpg")

        let hydration = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertTrue(hydration.allowed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
    }

    func testEqualLocalMetadataHydrationIsIdempotent() async throws {
        let fixture = try makeFixture()
        let before = try Data(contentsOf: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id))

        let first = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()
        let afterFirst = try Data(contentsOf: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id))
        let second = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()
        let afterSecond = try Data(contentsOf: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id))

        XCTAssertTrue(first.allowed)
        XCTAssertTrue(second.allowed)
        XCTAssertEqual(before, afterFirst)
        XCTAssertEqual(afterFirst, afterSecond)
    }

    func testLocalNewerStillBlocksHydration() async throws {
        let fixture = try makeFixture(generatedAt: Date(timeIntervalSinceReferenceDate: 1_000))
        let newerSession = Session(
            id: fixture.session.id,
            propertyID: fixture.property.id,
            startedAt: fixture.session.startedAt,
            status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            exportedAt: nil,
            isSealed: true,
            firstDeliveredAt: nil,
            reExportExpiresAt: nil
        )
        _ = try fixture.store.upsertSession(newerSession)
        try saveMetadata(store: fixture.store, property: fixture.property, session: newerSession, orgID: fixture.orgID)

        let hydration = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertFalse(hydration.allowed)
        XCTAssertEqual(hydration.blockedReason, "local_newer_conflict")
    }

    func testProductionHydrationRemainsBlockedBeforeFetchOrDownload() async throws {
        let store = LocalStore(testStorageRootURL: try makeTempStorageRoot())
        let appState = AppState(
            localStore: store,
            userDefaults: makeDefaults(),
            environment: productionValidationEnvironment(),
            sessionSnapshotRowsFetchOverride: { _, _, _ in
                XCTFail("Production hydration should block before snapshot row fetch.")
                return []
            },
            sessionSnapshotStorageDownloadOverride: { _, _ in
                XCTFail("Production hydration should block before snapshot payload download.")
                return Data()
            },
            disableCloudBackupForTests: true
        )

        let hydration = await appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertFalse(hydration.allowed)
        XCTAssertEqual(hydration.blockedReason, "production_hydration_disabled")
        XCTAssertNil(appState.localDiagnostics.sessionSnapshotUpload.lastRestoreDiagnosticsAt)
    }
}
