import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C28AutomaticSnapshotMetadataRecallTests: XCTestCase {
    private struct Fixture {
        var deviceBStore: LocalStore
        var appState: AppState
        var orgID: UUID
        var property: Property
        var session: Session
        var shotID: UUID
        var issueID: UUID
        var guidedID: UUID
        var row: AppState.SessionSnapshotUploadRow
        var object: AppState.SessionSnapshotStorageObject
    }

    private func makeTempStorageRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C28-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C28-\(UUID().uuidString)") ?? .standard
        defaults.set(true, forKey: "session_snapshot_shadow_write_enabled")
        return defaults
    }

    private func environment() -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key"
        ]
    }

    private func makeFixture(
        generatedAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        rows: ((AppState.SessionSnapshotUploadRow) -> [AppState.SessionSnapshotUploadRow])? = nil,
        payloadData: ((AppState.SessionSnapshotStorageObject) -> Data)? = nil
    ) throws -> Fixture {
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let shotID = UUID()
        let issueID = UUID()
        let guidedID = UUID()

        let deviceAStore = LocalStore(testStorageRootURL: try makeTempStorageRoot("A"))
        _ = try deviceAStore.createOrganization(Organization(id: orgID, name: "2C28 Org"))
        let propertyA = try deviceAStore.createProperty(Property(id: propertyID, orgId: orgID, name: "2C28 Property"))
        let session = try deviceAStore.upsertSession(
            Session(
                id: sessionID,
                propertyID: propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                exportedAt: nil,
                isSealed: true,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil
            )
        )
        try saveMetadata(
            store: deviceAStore,
            property: propertyA,
            session: session,
            orgID: orgID,
            shotID: shotID,
            issueID: issueID,
            guidedID: guidedID,
            shotUpdatedAt: Date(timeIntervalSinceReferenceDate: 130),
            issueLastSeenAt: Date(timeIntervalSinceReferenceDate: 130),
            guidedShotCapturedAt: Date(timeIntervalSinceReferenceDate: 120),
            note: "snapshot metadata hydration test",
            guidedTitle: "North overview"
        )

        let artifactAppState = AppState(
            localStore: deviceAStore,
            userDefaults: makeDefaults(),
            environment: environment(),
            sessionSnapshotStorageUploadOverride: { _ in },
            sessionSnapshotRowInsertOverride: { _ in },
            disableCloudBackupForTests: true
        )
        let artifacts = try artifactAppState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: propertyID,
            sessionID: sessionID,
            generatedAt: generatedAt
        )

        let deviceBStore = LocalStore(testStorageRootURL: try makeTempStorageRoot("B"))
        _ = try deviceBStore.createOrganization(Organization(id: orgID, name: "2C28 Org"))
        let propertyB = try deviceBStore.createProperty(Property(id: propertyID, orgId: orgID, name: "2C28 Property"))
        let appState = AppState(
            localStore: deviceBStore,
            userDefaults: makeDefaults(),
            environment: environment(),
            sessionSnapshotRowsFetchOverride: { _, requestedPropertyID, requestedSessionID in
                XCTAssertEqual(requestedPropertyID, propertyID)
                XCTAssertNil(requestedSessionID)
                return rows?(artifacts.row) ?? [artifacts.row]
            },
            sessionSnapshotStorageDownloadOverride: { _, _ in
                payloadData?(artifacts.object) ?? artifacts.object.payloadData
            },
            disableCloudBackupForTests: true
        )
        appState.selectedPropertyID = propertyID
        appState._debugSetOrganizationContextForTests(
            memberships: [ActiveOrganizationMembership(id: orgID, name: "2C28 Org", role: "admin")],
            activeOrganizationID: orgID,
            ready: true
        )
        appState._debugRefreshPropertiesLocallyForTests()

        return Fixture(
            deviceBStore: deviceBStore,
            appState: appState,
            orgID: orgID,
            property: propertyB,
            session: session,
            shotID: shotID,
            issueID: issueID,
            guidedID: guidedID,
            row: artifacts.row,
            object: artifacts.object
        )
    }

    private func saveMetadata(
        store: LocalStore,
        property: Property,
        session: Session,
        orgID: UUID,
        shotID: UUID,
        issueID: UUID,
        guidedID: UUID,
        shotUpdatedAt: Date,
        issueLastSeenAt: Date,
        guidedShotCapturedAt: Date,
        note: String,
        guidedTitle: String
    ) throws {
        let shot = ShotMetadata(
            shotID: shotID,
            propertyID: property.id,
            sessionID: session.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 120),
            updatedAt: shotUpdatedAt,
            building: "A",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            shotKey: "a-north-overview-1",
            isGuided: true,
            isFlagged: true,
            issueID: issueID,
            issueStatus: "active",
            noteText: note,
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
            currentReason: note,
            firstSeenAt: Date(timeIntervalSinceReferenceDate: 120),
            lastSeenAt: issueLastSeenAt,
            lastCaptureSessionId: session.id,
            detailNote: note,
            shotKey: shot.shotKey
        )
        let guided = GuidedShot(
            id: guidedID,
            title: guidedTitle,
            building: "A",
            targetElevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            referenceImagePath: "References/reference.jpg",
            shot: Shot(id: shotID, capturedAt: guidedShotCapturedAt),
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

    private func seedDeviceBMetadata(
        fixture: Fixture,
        shotUpdatedAt: Date,
        issueLastSeenAt: Date,
        guidedShotCapturedAt: Date,
        note: String,
        guidedTitle: String
    ) throws {
        _ = try fixture.deviceBStore.upsertSession(fixture.session)
        try saveMetadata(
            store: fixture.deviceBStore,
            property: fixture.property,
            session: fixture.session,
            orgID: fixture.orgID,
            shotID: fixture.shotID,
            issueID: fixture.issueID,
            guidedID: fixture.guidedID,
            shotUpdatedAt: shotUpdatedAt,
            issueLastSeenAt: issueLastSeenAt,
            guidedShotCapturedAt: guidedShotCapturedAt,
            note: note,
            guidedTitle: guidedTitle
        )
    }

    func testPropertyOpenSnapshotRecallHydratesMissingSessionFlaggedAndGuidedMetadata() async throws {
        let fixture = try makeFixture()

        let result = await fixture.appState.hydrateMetadataFromLatestVerifiedSessionSnapshotForPropertyOpen(
            propertyID: fixture.property.id,
            activeOrganizationID: fixture.orgID
        )

        let sessions = try fixture.deviceBStore.fetchSessions(propertyID: fixture.property.id)
        let metadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let observations = try fixture.deviceBStore.fetchObservations(propertyID: fixture.property.id)
        let guided = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.sourceSnapshotID, fixture.row.id)
        XCTAssertEqual(sessions.map(\.id), [fixture.session.id])
        XCTAssertEqual(metadata.shots.count, 1)
        XCTAssertEqual(observations.map(\.id), [fixture.issueID])
        XCTAssertEqual(guided.map(\.id), [fixture.guidedID])
        XCTAssertEqual(guided.first?.title, "North overview")
        XCTAssertNil(diagnostics.lastHydrationAt)
        XCTAssertNil(diagnostics.lastRestoreDiagnosticsAt)
    }

    func testNewerLocalMetadataIsPreserved() async throws {
        let fixture = try makeFixture()
        try seedDeviceBMetadata(
            fixture: fixture,
            shotUpdatedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            issueLastSeenAt: Date(timeIntervalSinceReferenceDate: 2_000),
            guidedShotCapturedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            note: "newer local note",
            guidedTitle: "Newer local guided"
        )

        _ = await fixture.appState.hydrateMetadataFromLatestVerifiedSessionSnapshotForPropertyOpen(
            propertyID: fixture.property.id,
            activeOrganizationID: fixture.orgID
        )

        let metadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let guided = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)

        XCTAssertEqual(metadata.shots.first?.noteText, "newer local note")
        XCTAssertEqual(metadata.issues.first?.detailNote, "newer local note")
        XCTAssertEqual(metadata.guidedShots.first?.title, "Newer local guided")
        XCTAssertEqual(guided.first?.title, "Newer local guided")
    }

    func testOlderLocalMetadataUpdatesFromSnapshot() async throws {
        let fixture = try makeFixture()
        try seedDeviceBMetadata(
            fixture: fixture,
            shotUpdatedAt: Date(timeIntervalSinceReferenceDate: 10),
            issueLastSeenAt: Date(timeIntervalSinceReferenceDate: 10),
            guidedShotCapturedAt: Date(timeIntervalSinceReferenceDate: 10),
            note: "older local note",
            guidedTitle: "Older local guided"
        )

        _ = await fixture.appState.hydrateMetadataFromLatestVerifiedSessionSnapshotForPropertyOpen(
            propertyID: fixture.property.id,
            activeOrganizationID: fixture.orgID
        )

        let metadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let guided = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)

        XCTAssertEqual(metadata.shots.first?.noteText, "snapshot metadata hydration test")
        XCTAssertEqual(metadata.issues.first?.detailNote, "snapshot metadata hydration test")
        XCTAssertEqual(metadata.guidedShots.first?.title, "North overview")
        XCTAssertEqual(guided.first?.title, "North overview")
    }

    func testDuplicateHydrationDoesNotDuplicateSessions() async throws {
        let fixture = try makeFixture()

        _ = await fixture.appState.hydrateMetadataFromLatestVerifiedSessionSnapshotForPropertyOpen(
            propertyID: fixture.property.id,
            activeOrganizationID: fixture.orgID
        )
        _ = await fixture.appState.hydrateMetadataFromLatestVerifiedSessionSnapshotForPropertyOpen(
            propertyID: fixture.property.id,
            activeOrganizationID: fixture.orgID
        )

        XCTAssertEqual(try fixture.deviceBStore.fetchSessions(propertyID: fixture.property.id).count, 1)
        XCTAssertEqual(try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id).count, 1)
        XCTAssertEqual(try fixture.deviceBStore.fetchObservations(propertyID: fixture.property.id).count, 1)
    }

    func testGuidedMetadataRestoresWithoutMedia() async throws {
        let fixture = try makeFixture()
        let mediaURL = fixture.deviceBStore
            .sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id)
            .deletingLastPathComponent()
            .appendingPathComponent("Originals/missing-original.jpg")

        _ = await fixture.appState.hydrateMetadataFromLatestVerifiedSessionSnapshotForPropertyOpen(
            propertyID: fixture.property.id,
            activeOrganizationID: fixture.orgID
        )

        let metadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        XCTAssertEqual(metadata.guidedShots.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
        XCTAssertNil(fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload.lastMediaRetrievalAt)
    }

    func testGuidedPresentationRecoversRowsFromCurrentSessionMetadataAfterRemoteConvergence() async throws {
        let fixture = try makeFixture()
        _ = try fixture.deviceBStore.upsertSession(fixture.session)
        try saveMetadata(
            store: fixture.deviceBStore,
            property: fixture.property,
            session: fixture.session,
            orgID: fixture.orgID,
            shotID: fixture.shotID,
            issueID: fixture.issueID,
            guidedID: fixture.guidedID,
            shotUpdatedAt: Date(timeIntervalSinceReferenceDate: 130),
            issueLastSeenAt: Date(timeIntervalSinceReferenceDate: 130),
            guidedShotCapturedAt: Date(timeIntervalSinceReferenceDate: 120),
            note: "current remote metadata",
            guidedTitle: "stale snapshot guided"
        )
        var metadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        metadata.guidedShots = []
        try fixture.deviceBStore.saveSessionMetadataAtomically(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            metadata: metadata
        )

        let recovered = ContentView.guidedShotsRecoveredFromCurrentSessionMetadata(
            metadata,
            session: fixture.session,
            sessionFolderURL: fixture.deviceBStore.sessionFolderURL(
                propertyID: fixture.property.id,
                sessionID: fixture.session.id
            )
        )

        XCTAssertEqual(recovered.map(\.id), [fixture.shotID])
        XCTAssertEqual(recovered.first?.title, "A N Overview")
        XCTAssertEqual(recovered.first?.shot?.id, fixture.shotID)
        XCTAssertEqual(recovered.first?.shot?.note, "current remote metadata")
    }

    func testMissingGuidedOriginalSchedulesCurrentSessionOperationalMediaHydration() async throws {
        let fixture = try makeFixture()
        _ = try fixture.deviceBStore.upsertSession(fixture.session)
        try saveMetadata(
            store: fixture.deviceBStore,
            property: fixture.property,
            session: fixture.session,
            orgID: fixture.orgID,
            shotID: fixture.shotID,
            issueID: fixture.issueID,
            guidedID: fixture.guidedID,
            shotUpdatedAt: Date(timeIntervalSinceReferenceDate: 130),
            issueLastSeenAt: Date(timeIntervalSinceReferenceDate: 130),
            guidedShotCapturedAt: Date(timeIntervalSinceReferenceDate: 120),
            note: "missing current guided original",
            guidedTitle: "North overview"
        )
        let metadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        let missingRequests = ContentView.currentGuidedOperationalHydrationRequests(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            metadata: metadata,
            localMediaExists: { _ in false }
        )
        let existingRequests = ContentView.currentGuidedOperationalHydrationRequests(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            metadata: metadata,
            localMediaExists: { _ in true }
        )

        XCTAssertEqual(missingRequests.count, 1)
        XCTAssertEqual(missingRequests.first?.propertyID, fixture.property.id)
        XCTAssertEqual(missingRequests.first?.sessionID, fixture.session.id)
        XCTAssertEqual(missingRequests.first?.shotID, fixture.shotID)
        XCTAssertEqual(missingRequests.first?.relativePathOverride, "Originals/missing-original.jpg")
        XCTAssertTrue(existingRequests.isEmpty)
    }

    func testGuidedRecoveryDoesNotStayBlankWhenTestMetadataIsCurrentAndRelaunches() async throws {
        let fixture = try makeFixture()
        _ = try fixture.deviceBStore.upsertSession(fixture.session)
        try saveMetadata(
            store: fixture.deviceBStore,
            property: fixture.property,
            session: fixture.session,
            orgID: fixture.orgID,
            shotID: fixture.shotID,
            issueID: fixture.issueID,
            guidedID: fixture.guidedID,
            shotUpdatedAt: Date(timeIntervalSinceReferenceDate: 130),
            issueLastSeenAt: Date(timeIntervalSinceReferenceDate: 130),
            guidedShotCapturedAt: Date(timeIntervalSinceReferenceDate: 120),
            note: "relaunch convergence",
            guidedTitle: "North overview"
        )
        var metadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        metadata.guidedShots = []
        try fixture.deviceBStore.saveSessionMetadataAtomically(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            metadata: metadata
        )
        let sessionFolder = fixture.deviceBStore.sessionFolderURL(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        let firstRefresh = ContentView.guidedShotsRecoveredFromCurrentSessionMetadata(
            metadata,
            session: fixture.session,
            sessionFolderURL: sessionFolder
        )
        let relaunchMetadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let relaunchRefresh = ContentView.guidedShotsRecoveredFromCurrentSessionMetadata(
            relaunchMetadata,
            session: fixture.session,
            sessionFolderURL: sessionFolder
        )

        XCTAssertFalse(firstRefresh.isEmpty)
        XCTAssertEqual(relaunchRefresh.map(\.id), firstRefresh.map(\.id))
        XCTAssertEqual(relaunchRefresh.first?.shot?.imageLocalIdentifier, firstRefresh.first?.shot?.imageLocalIdentifier)
    }

    func testMissingSnapshotDoesNotCorruptLocalProperty() async throws {
        let fixture = try makeFixture(rows: { _ in [] })

        let result = await fixture.appState.hydrateMetadataFromLatestVerifiedSessionSnapshotForPropertyOpen(
            propertyID: fixture.property.id,
            activeOrganizationID: fixture.orgID
        )

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "snapshot_row_not_found")
        XCTAssertTrue(try fixture.deviceBStore.fetchSessions(propertyID: fixture.property.id).isEmpty)
        XCTAssertTrue(try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id).isEmpty)
        XCTAssertTrue(try fixture.deviceBStore.fetchObservations(propertyID: fixture.property.id).isEmpty)
    }

    func testRelaunchRetryRemainsIdempotent() async throws {
        let fixture = try makeFixture()

        _ = await fixture.appState.hydrateMetadataFromLatestVerifiedSessionSnapshotForPropertyOpen(
            propertyID: fixture.property.id,
            activeOrganizationID: fixture.orgID
        )
        let relaunched = AppState(
            localStore: fixture.deviceBStore,
            userDefaults: makeDefaults(),
            environment: environment(),
            sessionSnapshotRowsFetchOverride: { _, _, _ in [fixture.row] },
            sessionSnapshotStorageDownloadOverride: { _, _ in fixture.object.payloadData },
            disableCloudBackupForTests: true
        )
        relaunched.selectedPropertyID = fixture.property.id
        relaunched._debugSetOrganizationContextForTests(
            memberships: [ActiveOrganizationMembership(id: fixture.orgID, name: "2C28 Org", role: "admin")],
            activeOrganizationID: fixture.orgID,
            ready: true
        )
        relaunched._debugRefreshPropertiesLocallyForTests()

        _ = await relaunched.hydrateMetadataFromLatestVerifiedSessionSnapshotForPropertyOpen(
            propertyID: fixture.property.id,
            activeOrganizationID: fixture.orgID
        )

        XCTAssertEqual(try fixture.deviceBStore.fetchSessions(propertyID: fixture.property.id).count, 1)
        XCTAssertEqual(try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id).count, 1)
        XCTAssertEqual(try fixture.deviceBStore.fetchObservations(propertyID: fixture.property.id).count, 1)
    }

    func testAutomaticRecallDoesNotChangeCanonicalActivationOrReadDiagnostics() async throws {
        let fixture = try makeFixture()

        _ = await fixture.appState.hydrateMetadataFromLatestVerifiedSessionSnapshotForPropertyOpen(
            propertyID: fixture.property.id,
            activeOrganizationID: fixture.orgID
        )

        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertNil(diagnostics.lastCanonicalReadDiagnosticsAt)
        XCTAssertFalse(diagnostics.lastCanonicalCandidateActivationAllowed)
        XCTAssertEqual(diagnostics.lastCanonicalCandidateActivationActiveSource, "local")
        XCTAssertFalse(diagnostics.lastCanonicalCandidateOverlayBuilt)
        XCTAssertFalse(diagnostics.runtimeSelectedSessionQAAuthAuthorized)
        XCTAssertEqual(diagnostics.lastSelectedSessionValidationPipelineState, "not_started")
    }
}
