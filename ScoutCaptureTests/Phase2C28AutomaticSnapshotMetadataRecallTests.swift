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

    func testAnotherSessionsDraftPhotoDoesNotBecomeGuidedReference() throws {
        let fixture = try makeFixture()
        let oldDraft = try fixture.deviceBStore.upsertSession(Session(
            propertyID: fixture.property.id,
            startedAt: Date(timeIntervalSinceReferenceDate: 50),
            status: .draft
        ))
        _ = try fixture.deviceBStore.upsertSession(fixture.session)

        let oldShotID = UUID()
        let oldOverview = GuidedShot(
            id: oldShotID,
            title: "A North Overview",
            building: "A",
            targetElevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            shot: Shot(id: oldShotID, capturedAt: oldDraft.startedAt),
            isCompleted: true
        )
        let uploadedElevation = GuidedShot(
            id: fixture.shotID,
            title: "A North Elevation",
            building: "A",
            targetElevation: "North",
            detailType: "Elevation",
            angleIndex: 1,
            shot: Shot(id: fixture.shotID, capturedAt: fixture.session.startedAt),
            isCompleted: true
        )
        var oldMetadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id, sessionID: oldDraft.id
        )
        oldMetadata.guidedShots = [oldOverview]
        try fixture.deviceBStore.saveSessionMetadataAtomically(
            propertyID: fixture.property.id, sessionID: oldDraft.id, metadata: oldMetadata
        )
        var uploadedMetadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id, sessionID: fixture.session.id
        )
        uploadedMetadata.guidedShots = [uploadedElevation]
        try fixture.deviceBStore.saveSessionMetadataAtomically(
            propertyID: fixture.property.id, sessionID: fixture.session.id, metadata: uploadedMetadata
        )
        try fixture.deviceBStore.saveGuidedShots(
            [oldOverview, uploadedElevation], propertyID: fixture.property.id
        )

        let nextSession = fixture.appState.fastRuntimePreviewSideControlPayload(
            propertyID: fixture.property.id,
            sessionType: .fullDocumentation,
            currentSessionID: UUID()
        )
        XCTAssertEqual(nextSession.guidedShots.map(\.id), [fixture.shotID])
        let nextAngles = fixture.appState.fastRuntimePropertyAngleReservations(
            propertyID: fixture.property.id,
            currentSessionID: UUID()
        )
        XCTAssertEqual(Set(nextAngles.map(\.detailType)), Set(["Elevation"]))

        let originalDraft = fixture.appState.fastRuntimePreviewSideControlPayload(
            propertyID: fixture.property.id,
            sessionType: .fullDocumentation,
            currentSessionID: oldDraft.id
        )
        XCTAssertEqual(Set(originalDraft.guidedShots.map(\.id)), Set([oldShotID, fixture.shotID]))
        XCTAssertEqual(try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id).count, 2)
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

    func testCompletedServerSnapshotRecoversGuidedPanelItemAndPhotoRequest() throws {
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
            note: "flagged shot",
            guidedTitle: "Flagged reference"
        )

        let guidedShotID = UUID()
        let remotePath = "orgs/test/sessions/\(fixture.session.id.uuidString)/guided.jpg"
        let ordinaryGuided = ShotMetadata(
            shotID: guidedShotID,
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 125),
            updatedAt: Date(timeIntervalSinceReferenceDate: 130),
            building: "A",
            elevation: "South",
            detailType: "Overview",
            angleIndex: 1,
            shotKey: "a-south-overview-1",
            isGuided: true,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: "guided shot",
            noteCategory: nil,
            originalFilename: "guided.jpg",
            originalRelativePath: remotePath,
            originalByteSize: 123,
            storageBucket: "media",
            storagePath: remotePath,
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
        var metadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        metadata.guidedShots = []
        metadata.shots.append(ordinaryGuided)
        try fixture.deviceBStore.saveSessionMetadataAtomically(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            metadata: metadata
        )

        let rows = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)
        XCTAssertEqual(rows.compactMap { $0.shot?.id }, [guidedShotID])
        XCTAssertEqual(rows.first?.isCompleted, true)
        XCTAssertEqual(rows.first?.shot?.imageLocalIdentifier,
                       fixture.deviceBStore.sessionFolderURL(
                        propertyID: fixture.property.id,
                        sessionID: fixture.session.id
                       ).appendingPathComponent(remotePath).path)

        let panel = fixture.appState.fastRuntimePreviewSideControlPayload(
            propertyID: fixture.property.id,
            sessionType: .fullDocumentation
        )
        XCTAssertEqual(panel.guidedShots.map(\.id), rows.map(\.id))
        let requests = fixture.appState.fastRuntimeGuidedPanelMediaHydrationRequests(
            propertyID: fixture.property.id,
            guidedShots: panel.guidedShots
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.sessionID, fixture.session.id)
        XCTAssertEqual(requests.first?.shotID, guidedShotID)
        XCTAssertEqual(try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id).count, 1)

        var retired = rows[0]
        retired.status = .retired
        retired.isRetired = true
        try fixture.deviceBStore.saveGuidedShots([retired], propertyID: fixture.property.id)
        let afterRetirement = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)
        XCTAssertEqual(afterRetirement.count, 1)
        XCTAssertTrue(afterRetirement[0].isRetired)
    }

    func testHistoricalRecoveryDoesNotReplaceNewerPhotoOnSameGuidedID() throws {
        let fixture = try makeFixture()
        _ = try fixture.deviceBStore.upsertSession(fixture.session)
        try saveMetadata(
            store: fixture.deviceBStore, property: fixture.property, session: fixture.session,
            orgID: fixture.orgID, shotID: fixture.shotID, issueID: fixture.issueID,
            guidedID: fixture.guidedID,
            shotUpdatedAt: Date(timeIntervalSinceReferenceDate: 130),
            issueLastSeenAt: Date(timeIntervalSinceReferenceDate: 130),
            guidedShotCapturedAt: Date(timeIntervalSinceReferenceDate: 120),
            note: "flagged shot", guidedTitle: "Flagged reference"
        )
        let olderID = UUID()
        let newerID = UUID()
        let remotePath = "orgs/test/older-downspout.jpg"
        let older = ShotMetadata(
            shotID: olderID, propertyID: fixture.property.id, sessionID: fixture.session.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 125),
            updatedAt: Date(timeIntervalSinceReferenceDate: 130),
            building: "A", elevation: "West", detailType: "Downspout", angleIndex: 1,
            shotKey: "a|west|downspout|1", isGuided: true, isFlagged: false,
            issueID: nil, issueStatus: nil, noteText: nil, noteCategory: nil,
            originalFilename: "older-downspout.jpg", originalRelativePath: remotePath,
            originalByteSize: 123, storageBucket: "media", storagePath: remotePath,
            stampedFilename: nil, stampedRelativePath: nil, captureMode: nil,
            lens: nil, exifOrientation: nil, latitude: nil, longitude: nil,
            accuracyMeters: nil, imageWidth: nil, imageHeight: nil
        )
        var metadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id, sessionID: fixture.session.id
        )
        metadata.guidedShots = []
        metadata.shots.append(older)
        try fixture.deviceBStore.saveSessionMetadataAtomically(
            propertyID: fixture.property.id, sessionID: fixture.session.id, metadata: metadata
        )
        let current = GuidedShot(
            id: olderID, title: "A North Window", building: "A", targetElevation: "North",
            detailType: "Window", angleIndex: 1,
            shot: Shot(id: newerID, capturedAt: Date(timeIntervalSinceReferenceDate: 300)),
            isCompleted: true
        )
        try fixture.deviceBStore.saveGuidedShots([current], propertyID: fixture.property.id)

        let rows = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, olderID)
        XCTAssertEqual(rows[0].detailType, "Window")
        XCTAssertEqual(rows[0].shot?.id, newerID)
    }

    func testCompletedSessionDoesNotReviveHistoricalPhotoOutsideItsGuidedChecklist() throws {
        let fixture = try makeFixture()
        try seedDeviceBMetadata(
            fixture: fixture,
            shotUpdatedAt: Date(timeIntervalSinceReferenceDate: 130),
            issueLastSeenAt: Date(timeIntervalSinceReferenceDate: 130),
            guidedShotCapturedAt: Date(timeIntervalSinceReferenceDate: 120),
            note: "historical overview",
            guidedTitle: "A North Overview"
        )
        let orphanID = UUID()
        var metadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id, sessionID: fixture.session.id
        )
        let historicalShot = ShotMetadata(
            shotID: orphanID, propertyID: fixture.property.id, sessionID: fixture.session.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 110),
            updatedAt: Date(timeIntervalSinceReferenceDate: 110),
            building: "A", elevation: "North", detailType: "Overview", angleIndex: 3,
            shotKey: ShotMetadata.makeShotKey(
                building: "A", elevation: "North", detailType: "Overview", angleIndex: 3
            ),
            isGuided: true, isFlagged: false, issueID: nil, issueStatus: nil,
            noteText: nil, noteCategory: nil, originalFilename: "orphan.jpg",
            originalRelativePath: "Originals/orphan.jpg", originalByteSize: 123,
            storageBucket: "media", storagePath: "orgs/test/orphan.jpg",
            stampedFilename: nil, stampedRelativePath: nil, captureMode: nil,
            lens: nil, exifOrientation: nil, latitude: nil, longitude: nil,
            accuracyMeters: nil, imageWidth: nil, imageHeight: nil
        )
        metadata.shots.append(historicalShot)
        try fixture.deviceBStore.saveSessionMetadataAtomically(
            propertyID: fixture.property.id, sessionID: fixture.session.id, metadata: metadata
        )

        let authoritative = try XCTUnwrap(metadata.guidedShots.first)
        let orphan = GuidedShot(
            id: orphanID, title: "A North Overview", building: "A",
            targetElevation: "North", detailType: "Overview", angleIndex: 3,
            shot: Shot(id: orphanID, capturedAt: historicalShot.createdAt), isCompleted: true
        )
        try fixture.deviceBStore.saveGuidedShots(
            [authoritative, orphan], propertyID: fixture.property.id
        )
        XCTAssertEqual(
            try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id).map(\.id),
            [authoritative.id]
        )

        let remoteData = Data("""
            [{"id":"\(orphanID.uuidString)","org_id":"\(fixture.orgID.uuidString)",
              "property_id":"\(fixture.property.id.uuidString)",
              "session_id":"\(fixture.session.id.uuidString)",
              "created_at":"2026-09-25T12:00:00Z",
              "building":"A","elevation":"North","detail_type":"Overview",
              "angle_index":3,"is_guided":true,"is_flagged":false,
              "storage_bucket":"media","storage_path":"orgs/test/orphan.jpg"}]
            """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let remote = try decoder.decode([RemoteShotMetadataRecord].self, from: remoteData)
        XCTAssertEqual(fixture.appState.mergeRemoteOrdinaryGuidedReferences(
            remote, propertyID: fixture.property.id, activeOrganizationID: fixture.orgID
        ), 0)
        XCTAssertEqual(
            try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id).map(\.id),
            [authoritative.id]
        )
    }

    func testHistoricalRemoteGuidedPhotoDoesNotFillRetiredChecklistSlot() throws {
        let fixture = try makeFixture()
        let active = GuidedShot(
            title: "A North Roofline", building: "A", targetElevation: "North",
            detailType: "Roofline", angleIndex: 1
        )
        let retired = GuidedShot(
            status: .retired, title: "A North Sidewalk", building: "A",
            targetElevation: "North", detailType: "Sidewalk", angleIndex: 1,
            isRetired: true
        )
        try fixture.deviceBStore.saveGuidedShots(
            [active, retired], propertyID: fixture.property.id
        )
        let historicalID = UUID()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let remote = try decoder.decode([RemoteShotMetadataRecord].self, from: Data(
            """
            [{"id":"\(historicalID.uuidString)","org_id":"\(fixture.orgID.uuidString)",
              "property_id":"\(fixture.property.id.uuidString)",
              "session_id":"\(fixture.session.id.uuidString)",
              "created_at":"2026-09-29T14:36:03Z",
              "building":"A","elevation":"North","detail_type":"Overview",
              "angle_index":3,"is_guided":true,"is_flagged":false,
              "storage_bucket":"media","storage_path":"orgs/test/old-overview.jpg"}]
            """.utf8
        ))

        XCTAssertEqual(fixture.appState.mergeRemoteOrdinaryGuidedReferences(
            remote, propertyID: fixture.property.id, activeOrganizationID: fixture.orgID
        ), 0)
        XCTAssertEqual(
            try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id).map(\.id),
            [active.id, retired.id]
        )
    }

    func testExistingGuidedChecklistReceivesRemoteRetireReclassifyAndRestore() throws {
        let fixture = try makeFixture()
        let first = GuidedShot(
            id: fixture.guidedID, title: "A North Overview", building: "A",
            targetElevation: "North", detailType: "Overview", angleIndex: 1,
            shot: Shot(id: fixture.shotID, capturedAt: Date(timeIntervalSince1970: 1_000)),
            isCompleted: true
        )
        let other = GuidedShot(
            title: "A South Overview", building: "A", targetElevation: "South",
            detailType: "Overview", angleIndex: 1
        )
        try fixture.deviceBStore.saveGuidedShots([first, other], propertyID: fixture.property.id)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func remote(_ lifecycle: String, updatedAt: String) throws -> [RemoteShotMetadataRecord] {
            try decoder.decode([RemoteShotMetadataRecord].self, from: Data("""
                [{"id":"\(fixture.shotID.uuidString)","org_id":"\(fixture.orgID.uuidString)",
                  "property_id":"\(fixture.property.id.uuidString)",
                  "session_id":"\(fixture.session.id.uuidString)",
                  "updated_at":"\(updatedAt)","lifecycle_updated_at":"\(updatedAt)",
                  "lifecycle_state":"\(lifecycle)","building":"B","elevation":"East",
                  "detail_type":"Roofline","angle_index":2,"is_guided":true}]
                """.utf8))
        }

        XCTAssertEqual(fixture.appState.mergeRemoteOrdinaryGuidedReferences(
            try remote("retired", updatedAt: "2026-11-20T12:00:00Z"),
            propertyID: fixture.property.id, activeOrganizationID: fixture.orgID
        ), 1)
        var rows = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].status, .retired)
        XCTAssertEqual(rows[0].building, "B")
        XCTAssertEqual(rows[0].targetElevation, "East")
        XCTAssertEqual(rows[0].detailType, "Roofline")
        XCTAssertEqual(rows[0].angleIndex, 2)
        XCTAssertEqual(rows[1].id, other.id)
        XCTAssertEqual(fixture.appState.mergeRemoteOrdinaryGuidedReferences(
            try remote("active", updatedAt: "2026-11-20T13:00:00Z"),
            propertyID: fixture.property.id, activeOrganizationID: fixture.orgID
        ), 1)
        rows = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)
        XCTAssertEqual(rows[0].status, .active)
        XCTAssertFalse(rows[0].isRetired)
    }

    func testGuidedReclassificationOnLaterPhotoUpdatesEarlierCheckpoint() throws {
        let fixture = try makeFixture()
        let laterShotID = UUID()
        let earlier = GuidedShot(
            id: fixture.guidedID, title: "A North Entry / Porch", building: "A",
            targetElevation: "North", detailType: "Entry / Porch", angleIndex: 2,
            shot: Shot(id: fixture.shotID, capturedAt: Date(timeIntervalSince1970: 1_000)),
            isCompleted: true
        )
        try fixture.deviceBStore.saveGuidedShots([earlier], propertyID: fixture.property.id)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let remote = try decoder.decode([RemoteShotMetadataRecord].self, from: Data("""
            [
              {"id":"\(fixture.shotID.uuidString)","org_id":"\(fixture.orgID.uuidString)",
               "property_id":"\(fixture.property.id.uuidString)","session_id":"\(fixture.session.id.uuidString)",
               "created_at":"2026-11-18T10:00:00Z","updated_at":"2026-11-18T10:00:00Z",
               "building":"A","elevation":"North","detail_type":"Entry / Porch","angle_index":2,
               "shot_key":"a|north|entry / porch|2","is_guided":true},
              {"id":"\(laterShotID.uuidString)","org_id":"\(fixture.orgID.uuidString)",
               "property_id":"\(fixture.property.id.uuidString)","session_id":"\(fixture.session.id.uuidString)",
               "created_at":"2026-11-19T10:00:00Z","updated_at":"2026-11-20T13:00:00Z",
               "building":"A","elevation":"North","detail_type":"Overview","angle_index":1,
               "shot_key":"a|north|overview|1",
               "logical_shot_identity":"\(fixture.session.id.uuidString.lowercased())|flagged|no-issue|a|north|entry / porch|2",
               "is_guided":true}
            ]
            """.utf8))

        XCTAssertEqual(fixture.appState.mergeRemoteOrdinaryGuidedReferences(
            remote, propertyID: fixture.property.id, activeOrganizationID: fixture.orgID
        ), 1)
        let rows = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].shot?.id, fixture.shotID)
        XCTAssertEqual(rows[0].detailType, "Overview")
        XCTAssertEqual(rows[0].angleIndex, 1)
    }

    func testReclassifiedReplacementDoesNotResurrectOlderGuidedCard() throws {
        let fixture = try makeFixture()
        let oldPoolID = UUID()
        let replacementID = UUID()
        let entry = GuidedShot(
            title: "A North Entry / Porch", building: "A", targetElevation: "North",
            detailType: "Entry / Porch", angleIndex: 1,
            shot: Shot(id: fixture.shotID, capturedAt: Date(timeIntervalSince1970: 1_000)),
            isCompleted: true
        )
        let oldPool = GuidedShot(
            id: oldPoolID, title: "A East Pool / Outdoor Amenities", building: "A",
            targetElevation: "East", detailType: "Pool / Outdoor Amenities", angleIndex: 1,
            shot: Shot(id: oldPoolID, capturedAt: Date(timeIntervalSince1970: 2_000)),
            isCompleted: true
        )
        let replacement = GuidedShot(
            id: replacementID, title: "A North Window", building: "A",
            targetElevation: "North", detailType: "Window", angleIndex: 1,
            shot: Shot(id: replacementID, capturedAt: Date(timeIntervalSince1970: 3_000)),
            isCompleted: true
        )
        try fixture.deviceBStore.saveGuidedShots(
            [entry, oldPool, replacement], propertyID: fixture.property.id
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let remote = try decoder.decode([RemoteShotMetadataRecord].self, from: Data("""
            [
              {"id":"\(fixture.shotID.uuidString)","org_id":"\(fixture.orgID.uuidString)",
               "property_id":"\(fixture.property.id.uuidString)","session_id":"\(fixture.session.id.uuidString)",
               "created_at":"2026-11-18T10:00:00Z","updated_at":"2026-11-18T10:00:00Z",
               "building":"A","elevation":"North","detail_type":"Entry / Porch","angle_index":1,
               "shot_key":"a|north|entry / porch|1","is_guided":true},
              {"id":"\(oldPoolID.uuidString)","org_id":"\(fixture.orgID.uuidString)",
               "property_id":"\(fixture.property.id.uuidString)","session_id":"\(fixture.session.id.uuidString)",
               "created_at":"2026-11-19T10:00:00Z","updated_at":"2026-11-19T10:00:00Z",
               "building":"A","elevation":"East","detail_type":"Pool / Outdoor Amenities","angle_index":1,
               "shot_key":"a|east|pool / outdoor amenities|1",
               "logical_shot_identity":"\(fixture.session.id.uuidString.lowercased())|flagged|no-issue|a|north|overview|2",
               "is_guided":true,"upload_state":"uploaded","storage_bucket":"media",
               "storage_path":"orgs/test/old-pool.jpg"},
              {"id":"\(replacementID.uuidString)","org_id":"\(fixture.orgID.uuidString)",
               "property_id":"\(fixture.property.id.uuidString)","session_id":"\(fixture.session.id.uuidString)",
               "created_at":"2026-11-20T10:00:00Z","updated_at":"2026-11-21T10:00:00Z",
               "building":"A","elevation":"North","detail_type":"Window","angle_index":1,
               "shot_key":"a|north|window|1",
               "logical_shot_identity":"\(fixture.session.id.uuidString.lowercased())|flagged|no-issue|a|east|pool / outdoor amenities|1",
               "is_guided":true,"upload_state":"uploaded","storage_bucket":"media",
               "storage_path":"orgs/test/new-window.jpg"}
            ]
            """.utf8))

        XCTAssertGreaterThan(fixture.appState.mergeRemoteOrdinaryGuidedReferences(
            remote, propertyID: fixture.property.id, activeOrganizationID: fixture.orgID
        ), 0)
        let rows = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter { $0.detailType == "Window" }.count, 1)
        XCTAssertFalse(rows.contains { $0.detailType == "Pool / Outdoor Amenities" })
        XCTAssertEqual(rows.first { $0.detailType == "Window" }?.shot?.id, replacementID)
        XCTAssertEqual(rows.first { $0.detailType == "Entry / Porch" }?.shot?.id, fixture.shotID)
    }

    func testSupersedesIdentityCollapsesGuidedCardsAcrossDifferentLabels() throws {
        let fixture = try makeFixture()
        let oldID = UUID()
        let newID = UUID()
        let old = GuidedShot(
            id: oldID, title: "A South Roofline", building: "A", targetElevation: "South",
            detailType: "Roofline", angleIndex: 1,
            shot: Shot(id: oldID, capturedAt: Date(timeIntervalSince1970: 2_000)),
            isCompleted: true
        )
        let current = GuidedShot(
            id: newID, title: "A East Elevation", building: "A", targetElevation: "East",
            detailType: "Elevation", angleIndex: 1,
            shot: Shot(id: newID, capturedAt: Date(timeIntervalSince1970: 3_000)),
            isCompleted: true
        )
        try fixture.deviceBStore.saveGuidedShots([old, current], propertyID: fixture.property.id)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let remote = try decoder.decode([RemoteShotMetadataRecord].self, from: Data("""
            [
              {"id":"\(oldID.uuidString)","org_id":"\(fixture.orgID.uuidString)",
               "property_id":"\(fixture.property.id.uuidString)","session_id":"\(fixture.session.id.uuidString)",
               "created_at":"2026-11-22T20:00:00Z","updated_at":"2026-11-22T20:00:00Z",
               "building":"A","elevation":"South","detail_type":"Roofline","angle_index":1,
               "shot_key":"a|south|roofline|1","is_guided":true,"upload_state":"uploaded",
               "storage_bucket":"media","storage_path":"orgs/test/old.jpg"},
              {"id":"\(newID.uuidString)","org_id":"\(fixture.orgID.uuidString)",
               "property_id":"\(fixture.property.id.uuidString)","session_id":"\(fixture.session.id.uuidString)",
               "created_at":"2026-11-22T21:00:00Z","updated_at":"2026-11-22T21:00:00Z",
               "building":"A","elevation":"East","detail_type":"Elevation","angle_index":1,
               "shot_key":"a|east|elevation|1","supersedes_shot_id":"\(oldID.uuidString)",
               "is_guided":true,"upload_state":"uploaded","storage_bucket":"media",
               "storage_path":"orgs/test/new.jpg"}
            ]
            """.utf8))

        XCTAssertGreaterThan(fixture.appState.mergeRemoteOrdinaryGuidedReferences(
            remote, propertyID: fixture.property.id, activeOrganizationID: fixture.orgID
        ), 0)
        let rows = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].shot?.id, newID)
        XCTAssertEqual(rows[0].targetElevation, "East")
        XCTAssertEqual(rows[0].detailType, "Elevation")
    }

    func testFastRuntimeGuidedReplacementKeepsPhotoLineageThroughNormalization() {
        let oldShotID = UUID()
        let context = AppState.FastRuntimeCaptureMetadataContext(
            building: "A", elevation: "East", detailType: "Elevation", angleIndex: 1,
            isGuided: true, isFlagged: false, captureIntentSource: "guided",
            supersedesShotID: oldShotID
        )
        let normalized = AppState.normalizedFastRuntimeMetadataContext(context)
        XCTAssertEqual(normalized.supersedesShotID, oldShotID)
        XCTAssertEqual(normalized.withAngleIndex(2).supersedesShotID, oldShotID)
        XCTAssertEqual(normalized.reclassified(
            building: "A", elevation: "South", detailType: "Roofline", angleIndex: 1
        ).supersedesShotID, oldShotID)
    }

    func testCurrentGuidedLineageExcludesLegacyOrphanRetake() throws {
        let baselineID = UUID()
        let entryID = UUID()
        let foundationID = UUID()
        let oldRetakeID = UUID()
        let oldReplacementID = UUID()
        let latestID = UUID()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rows = try decoder.decode([RemoteShotMetadataRecord].self, from: Data("""
            [
              {"id":"\(entryID)","session_id":"\(baselineID)","created_at":"2026-11-20T10:00:00Z",
               "shot_key":"b1|north|entry / porch|1","capture_kind":"captured","is_guided":true},
              {"id":"\(foundationID)","session_id":"\(baselineID)","created_at":"2026-11-20T10:01:00Z",
               "shot_key":"b1|south|foundation|1","capture_kind":"captured","is_guided":true},
              {"id":"\(oldRetakeID)","created_at":"2026-11-21T10:00:00Z",
               "shot_key":"b1|south|roofline|1","capture_kind":"retake","is_guided":true},
              {"id":"\(oldReplacementID)","created_at":"2026-11-22T10:00:00Z",
               "shot_key":"b1|east|elevation|1","capture_kind":"retake","is_guided":true,
               "supersedes_shot_id":"\(oldRetakeID)"},
              {"id":"\(latestID)","created_at":"2026-11-23T10:00:00Z",
               "shot_key":"b1|west|sidewalk|2","capture_kind":"captured","is_guided":true,
               "supersedes_shot_id":"\(foundationID)"}
            ]
            """.utf8))
        let eligible = AppState.currentGuidedRemoteShotIDs(
            rows, baselineSessionID: baselineID,
            baselineShotIDs: [entryID, foundationID],
            baselineShotKeys: ["b1|north|entry / porch|1", "b1|south|foundation|1"],
            baselineStartedAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-20T10:00:00Z"))
        )
        XCTAssertTrue(eligible.contains(latestID))
        XCTAssertFalse(eligible.contains(oldRetakeID))
        XCTAssertFalse(eligible.contains(oldReplacementID))
    }

    func testHistoricalRecoveryDoesNotRecreateOrphanOutsideLatestBaseline() throws {
        let fixture = try makeFixture()
        _ = try fixture.deviceBStore.upsertSession(fixture.session)
        try saveMetadata(
            store: fixture.deviceBStore, property: fixture.property, session: fixture.session,
            orgID: fixture.orgID, shotID: fixture.shotID, issueID: fixture.issueID,
            guidedID: fixture.guidedID,
            shotUpdatedAt: Date(timeIntervalSinceReferenceDate: 130),
            issueLastSeenAt: Date(timeIntervalSinceReferenceDate: 130),
            guidedShotCapturedAt: Date(timeIntervalSinceReferenceDate: 120),
            note: "baseline", guidedTitle: "Baseline"
        )
        let baselineShotID = UUID()
        let baselinePath = "orgs/test/baseline-guided.jpg"
        let baselineShot = ShotMetadata(
            shotID: baselineShotID, propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 150),
            updatedAt: Date(timeIntervalSinceReferenceDate: 150),
            building: "A", elevation: "North", detailType: "Entry / Porch", angleIndex: 1,
            shotKey: "a|north|entry / porch|1", isGuided: true, isFlagged: false,
            issueID: nil, issueStatus: nil, noteText: nil, noteCategory: nil,
            originalFilename: "baseline.jpg", originalRelativePath: baselinePath,
            originalByteSize: 123, storageBucket: "media", storagePath: baselinePath,
            stampedFilename: nil, stampedRelativePath: nil, captureMode: nil,
            lens: nil, exifOrientation: nil, latitude: nil, longitude: nil,
            accuracyMeters: nil, imageWidth: nil, imageHeight: nil
        )
        var baselineMetadata = try fixture.deviceBStore.loadSessionMetadata(
            propertyID: fixture.property.id, sessionID: fixture.session.id
        )
        baselineMetadata.guidedShots = []
        baselineMetadata.shots.append(baselineShot)
        try fixture.deviceBStore.saveSessionMetadataAtomically(
            propertyID: fixture.property.id, sessionID: fixture.session.id,
            metadata: baselineMetadata
        )

        let follow = try fixture.deviceBStore.upsertSession(Session(
            propertyID: fixture.property.id, fullDocumentationMode: .followUp,
            startedAt: Date(timeIntervalSinceReferenceDate: 300), status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 400), isSealed: true
        ))
        let orphanShot = ShotMetadata(
            shotID: UUID(), propertyID: fixture.property.id, sessionID: follow.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 350),
            updatedAt: Date(timeIntervalSinceReferenceDate: 350),
            building: "A", elevation: "East", detailType: "Elevation", angleIndex: 1,
            shotKey: "a|east|elevation|1", isGuided: true, isFlagged: false,
            issueID: nil, issueStatus: nil, captureKind: "retake",
            noteText: nil, noteCategory: nil, originalFilename: "orphan.jpg",
            originalRelativePath: "orgs/test/orphan.jpg", originalByteSize: 123,
            storageBucket: "media", storagePath: "orgs/test/orphan.jpg",
            stampedFilename: nil, stampedRelativePath: nil, captureMode: nil,
            lens: nil, exifOrientation: nil, latitude: nil, longitude: nil,
            accuracyMeters: nil, imageWidth: nil, imageHeight: nil
        )
        var followMetadata = baselineMetadata
        followMetadata.sessionID = follow.id
        followMetadata.fullDocumentationMode = .followUp
        followMetadata.shots = [orphanShot]
        try fixture.deviceBStore.saveSessionMetadataAtomically(
            propertyID: fixture.property.id, sessionID: follow.id,
            metadata: followMetadata
        )

        let rows = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)
        XCTAssertTrue(rows.contains { $0.shot?.id == baselineShotID })
        XCTAssertFalse(rows.contains { $0.shot?.id == orphanShot.shotID })
    }

    func testRemoteGuidedReferenceAppearsWithoutAnyLocalSessionSnapshot() throws {
        let fixture = try makeFixture()
        let guidedShotID = UUID()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let remoteShots = try decoder.decode([RemoteShotMetadataRecord].self, from: Data(
            """
            [
              {
                "id": "\(fixture.shotID.uuidString)",
                "org_id": "\(fixture.orgID.uuidString)",
                "property_id": "\(fixture.property.id.uuidString)",
                "session_id": "\(fixture.session.id.uuidString)",
                "created_at": "2026-09-25T12:00:00Z",
                "building": "A",
                "elevation": "South",
                "detail_type": "Overview",
                "angle_index": 2,
                "is_guided": true,
                "is_flagged": true,
                "issue_id": "\(fixture.issueID.uuidString)",
                "issue_status": "active",
                "storage_bucket": "media",
                "storage_path": "orgs/test/flagged.jpg"
              },
              {
                "id": "\(guidedShotID.uuidString)",
                "org_id": "\(fixture.orgID.uuidString)",
                "property_id": "\(fixture.property.id.uuidString)",
                "session_id": "\(fixture.session.id.uuidString)",
                "created_at": "2026-09-25T12:01:00Z",
                "building": "A",
                "elevation": "South",
                "detail_type": "Overview",
                "angle_index": 1,
                "is_guided": true,
                "is_flagged": false,
                "storage_bucket": "media",
                "storage_path": "orgs/test/guided.jpg"
              }
            ]
            """.utf8
        ))

        _ = try fixture.deviceBStore.createObservation(Observation(
            id: fixture.issueID,
            propertyID: fixture.property.id,
            sessionID: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            statement: "Flagged issue",
            status: .active,
            linkedShotID: fixture.shotID
        ))
        XCTAssertTrue(try fixture.deviceBStore.fetchSessions(propertyID: fixture.property.id).isEmpty)
        XCTAssertEqual(
            fixture.appState.mergeRemoteFlaggedShotReferences(
                remoteShots,
                propertyID: fixture.property.id,
                activeOrganizationID: fixture.orgID
            ),
            1
        )
        let flagged = try XCTUnwrap(fixture.deviceBStore.fetchObservations(
            propertyID: fixture.property.id
        ).first)
        XCTAssertEqual(flagged.status, .active)
        XCTAssertEqual(flagged.linkedShotID, fixture.shotID)
        XCTAssertEqual(flagged.shots.map(\.id), [fixture.shotID])
        XCTAssertEqual(flagged.guidedShots.map(\.angleIndex), [2])
        XCTAssertEqual(flagged.guidedShots.first?.shot?.id, fixture.shotID)
        XCTAssertEqual(flagged.shots.first?.imageLocalIdentifier,
                       fixture.deviceBStore.sessionFolderURL(
                        propertyID: fixture.property.id,
                        sessionID: fixture.session.id
                       ).appendingPathComponent("Originals/flagged.jpg").path)
        let flaggedRequests = fixture.appState.fastRuntimeIssuePanelMediaHydrationRequests(
            propertyID: fixture.property.id,
            observations: [flagged]
        )
        XCTAssertEqual(flaggedRequests.count, 1)
        XCTAssertEqual(flaggedRequests.first?.sessionID, fixture.session.id)
        XCTAssertEqual(flaggedRequests.first?.shotID, fixture.shotID)
        XCTAssertEqual(flaggedRequests.first?.relativePathOverride, "Originals/flagged.jpg")
        XCTAssertEqual(
            fixture.appState.mergeRemoteFlaggedShotReferences(
                remoteShots,
                propertyID: fixture.property.id,
                activeOrganizationID: fixture.orgID
            ),
            0
        )
        XCTAssertEqual(
            fixture.appState.mergeRemoteOrdinaryGuidedReferences(
                remoteShots,
                propertyID: fixture.property.id,
                activeOrganizationID: fixture.orgID
            ),
            1
        )
        let rows = try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id)
        XCTAssertEqual(rows.compactMap { $0.shot?.id }, [guidedShotID])
        let southAngles = fixture.appState.fastRuntimePropertyAngleReservations(
            propertyID: fixture.property.id
        ).filter { $0.building == "A" && $0.elevation == "South" && $0.detailType == "Overview" }
        XCTAssertEqual(Set(southAngles.map(\.angleIndex)), Set([1, 2]))
        XCTAssertEqual(rows.first?.referenceImagePath,
                       fixture.deviceBStore.sessionFolderURL(
                        propertyID: fixture.property.id,
                        sessionID: fixture.session.id
                       ).appendingPathComponent("Originals/guided.jpg").path)

        let panel = fixture.appState.fastRuntimePreviewSideControlPayload(
            propertyID: fixture.property.id,
            sessionType: .fullDocumentation
        )
        XCTAssertEqual(panel.guidedShots.map(\.id), [guidedShotID])
        let requests = fixture.appState.fastRuntimeGuidedPanelMediaHydrationRequests(
            propertyID: fixture.property.id,
            guidedShots: panel.guidedShots
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.sessionID, fixture.session.id)
        XCTAssertEqual(requests.first?.shotID, guidedShotID)
        XCTAssertEqual(requests.first?.relativePathOverride, "Originals/guided.jpg")
        XCTAssertEqual(
            fixture.appState.mergeRemoteOrdinaryGuidedReferences(
                remoteShots,
                propertyID: fixture.property.id,
                activeOrganizationID: fixture.orgID
            ),
            0
        )
        XCTAssertEqual(try fixture.deviceBStore.fetchGuidedShots(propertyID: fixture.property.id).count, 1)
    }

    func testFlaggedPanelHydratesNewestPunchlistShotWithoutLocalSessions() throws {
        let fixture = try makeFixture()
        let newerSessionID = UUID()
        let newerShotID = UUID()
        _ = try fixture.deviceBStore.createObservation(Observation(
            id: fixture.issueID,
            propertyID: fixture.property.id,
            sessionID: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            statement: "Flagged issue",
            status: .active,
            linkedShotID: fixture.shotID
        ))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let remoteShots = try decoder.decode([RemoteShotMetadataRecord].self, from: Data(
            """
            [
              {
                "id": "\(fixture.shotID.uuidString)",
                "org_id": "\(fixture.orgID.uuidString)",
                "property_id": "\(fixture.property.id.uuidString)",
                "session_id": "\(fixture.session.id.uuidString)",
                "created_at": "2026-09-23T12:00:00Z",
                "is_flagged": true,
                "issue_id": "\(fixture.issueID.uuidString)",
                "storage_bucket": "media",
                "storage_path": "orgs/test/original-flagged.jpg"
              },
              {
                "id": "\(newerShotID.uuidString)",
                "org_id": "\(fixture.orgID.uuidString)",
                "property_id": "\(fixture.property.id.uuidString)",
                "session_id": "\(newerSessionID.uuidString)",
                "created_at": "2026-09-25T12:00:00Z",
                "is_flagged": true,
                "issue_id": "\(fixture.issueID.uuidString)",
                "storage_bucket": "media",
                "storage_path": "orgs/test/newer-punchlist.jpg"
              }
            ]
            """.utf8
        ))

        XCTAssertTrue(try fixture.deviceBStore.fetchSessions(propertyID: fixture.property.id).isEmpty)
        XCTAssertEqual(
            fixture.appState.mergeRemoteFlaggedShotReferences(
                remoteShots,
                propertyID: fixture.property.id,
                activeOrganizationID: fixture.orgID
            ),
            2
        )
        let observation = try XCTUnwrap(fixture.deviceBStore.fetchObservations(
            propertyID: fixture.property.id
        ).first)
        XCTAssertEqual(observation.status, .active)
        XCTAssertEqual(observation.linkedShotID, fixture.shotID)
        XCTAssertEqual(Set(observation.shots.map(\.id)), Set([fixture.shotID, newerShotID]))
        let requests = fixture.appState.fastRuntimeIssuePanelMediaHydrationRequests(
            propertyID: fixture.property.id,
            observations: [observation]
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.sessionID, newerSessionID)
        XCTAssertEqual(requests.first?.shotID, newerShotID)
        XCTAssertEqual(requests.first?.relativePathOverride, "Originals/newer-punchlist.jpg")
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
