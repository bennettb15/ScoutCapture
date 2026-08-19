import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C25CGuardedSnapshotHydrationTests: XCTestCase {
    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C25C-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C25C-\(UUID().uuidString)") ?? .standard
        defaults.set(true, forKey: "session_snapshot_shadow_write_enabled")
        return defaults
    }

    private func localEnvironment() -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key"
        ]
    }

    private func makeFixture(
        generatedAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        rowTransform: ((AppState.SessionSnapshotUploadRow) -> AppState.SessionSnapshotUploadRow)? = nil,
        parentOverride: ((UUID, UUID, UUID) async throws -> AppState.SessionSnapshotAuthPreflightRemoteParentStatus)? = nil
    ) throws -> (
        store: LocalStore,
        appState: AppState,
        property: Property,
        session: Session,
        orgID: UUID,
        row: AppState.SessionSnapshotUploadRow,
        object: AppState.SessionSnapshotStorageObject
    ) {
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let orgID = UUID()
        _ = try store.createOrganization(Organization(id: orgID, name: "Hydration Org"))
        let property = try store.createProperty(Property(id: UUID(), orgId: orgID, name: "Hydration Property"))
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
        let row = rowTransform?(artifacts.row) ?? artifacts.row
        let object = artifacts.object
        let appState = AppState(
            localStore: store,
            userDefaults: makeDefaults(),
            environment: localEnvironment(),
            sessionSnapshotRowsFetchOverride: { _, _, _ in [row] },
            sessionSnapshotStorageDownloadOverride: { _, _ in object.payloadData },
            sessionSnapshotRemoteParentPreflightOverride: parentOverride ?? { _, _, _ in
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
        return (store, appState, property, session, orgID, row, object)
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
            noteText: "hydration test",
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
            detailNote: "hydrated issue",
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

    private func rowWithChecksumMismatch(_ row: AppState.SessionSnapshotUploadRow) -> AppState.SessionSnapshotUploadRow {
        AppState.SessionSnapshotUploadRow(
            id: row.id,
            orgID: row.orgID,
            propertyID: row.propertyID,
            sessionID: row.sessionID,
            snapshotKind: row.snapshotKind,
            snapshotSchemaVersion: row.snapshotSchemaVersion,
            sessionMetadataSchemaVersion: row.sessionMetadataSchemaVersion,
            trigger: row.trigger,
            sessionStatus: row.sessionStatus,
            isSealed: row.isSealed,
            exportedAt: row.exportedAt,
            firstDeliveredAt: row.firstDeliveredAt,
            reExportExpiresAt: row.reExportExpiresAt,
            payloadStorageBucket: row.payloadStorageBucket,
            payloadStoragePath: row.payloadStoragePath,
            payloadByteSize: row.payloadByteSize,
            rawSessionJSONSHA256: row.rawSessionJSONSHA256,
            snapshotPayloadSHA256: String(repeating: "b", count: 64),
            manifest: row.manifest,
            shotCount: row.shotCount,
            issueCount: row.issueCount,
            guidedCount: row.guidedCount,
            mediaManifestCount: row.mediaManifestCount,
            missingLocalOriginalsCount: row.missingLocalOriginalsCount,
            supabaseStorageMetadataCount: row.supabaseStorageMetadataCount,
            createdBy: row.createdBy,
            updatedBy: row.updatedBy,
            createdAt: row.createdAt
        )
    }

    private func rowWithUnsupportedSchema(_ row: AppState.SessionSnapshotUploadRow) -> AppState.SessionSnapshotUploadRow {
        AppState.SessionSnapshotUploadRow(
            id: row.id,
            orgID: row.orgID,
            propertyID: row.propertyID,
            sessionID: row.sessionID,
            snapshotKind: row.snapshotKind,
            snapshotSchemaVersion: 99,
            sessionMetadataSchemaVersion: row.sessionMetadataSchemaVersion,
            trigger: row.trigger,
            sessionStatus: row.sessionStatus,
            isSealed: row.isSealed,
            exportedAt: row.exportedAt,
            firstDeliveredAt: row.firstDeliveredAt,
            reExportExpiresAt: row.reExportExpiresAt,
            payloadStorageBucket: row.payloadStorageBucket,
            payloadStoragePath: row.payloadStoragePath,
            payloadByteSize: row.payloadByteSize,
            rawSessionJSONSHA256: row.rawSessionJSONSHA256,
            snapshotPayloadSHA256: row.snapshotPayloadSHA256,
            manifest: row.manifest,
            shotCount: row.shotCount,
            issueCount: row.issueCount,
            guidedCount: row.guidedCount,
            mediaManifestCount: row.mediaManifestCount,
            missingLocalOriginalsCount: row.missingLocalOriginalsCount,
            supabaseStorageMetadataCount: row.supabaseStorageMetadataCount,
            createdBy: row.createdBy,
            updatedBy: row.updatedBy,
            createdAt: row.createdAt
        )
    }

    func testVerifiedSnapshotHydratesMetadataSuccessfully() async throws {
        let fixture = try makeFixture()
        try fixture.store.deleteSession(id: fixture.session.id, propertyID: fixture.property.id)

        let result = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()
        let metadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)

        XCTAssertTrue(result.allowed)
        XCTAssertNil(result.blockedReason)
        XCTAssertEqual(result.hydratedShotCount, 1)
        XCTAssertEqual(result.hydratedIssueCount, 1)
        XCTAssertEqual(result.hydratedGuidedCount, 1)
        XCTAssertEqual(metadata.shots.count, 1)
        XCTAssertEqual(metadata.issues.count, 1)
        XCTAssertEqual(metadata.guidedShots.count, 1)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastHydrationSourceSnapshotID, fixture.row.id)
    }

    func testLocalNewerConflictBlocksHydration() async throws {
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

        let result = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "local_newer_conflict")
    }

    func testChecksumMismatchBlocksHydration() async throws {
        let fixture = try makeFixture(rowTransform: rowWithChecksumMismatch)
        try fixture.store.deleteSession(id: fixture.session.id, propertyID: fixture.property.id)

        let result = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "checksum_failed")
        XCTAssertTrue(try fixture.store.fetchSessionsForCacheBuild(propertyID: fixture.property.id).isEmpty)
    }

    func testUnsupportedSchemaBlocksHydration() async throws {
        let fixture = try makeFixture(rowTransform: rowWithUnsupportedSchema)
        try fixture.store.deleteSession(id: fixture.session.id, propertyID: fixture.property.id)

        let result = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "unsupported_schema")
        XCTAssertTrue(try fixture.store.fetchSessionsForCacheBuild(propertyID: fixture.property.id).isEmpty)
    }

    func testHydrationDoesNotRestoreMediaFiles() async throws {
        let fixture = try makeFixture()
        try fixture.store.deleteSession(id: fixture.session.id, propertyID: fixture.property.id)
        let mediaURL = fixture.store
            .sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id)
            .deletingLastPathComponent()
            .appendingPathComponent("Originals/missing-original.jpg")

        _ = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()

        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
    }

    func testHydrationDoesNotOverwriteNewerLocalState() async throws {
        let fixture = try makeFixture(generatedAt: Date(timeIntervalSinceReferenceDate: 1_000))
        let before = try Data(contentsOf: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id))
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
        let newer = try Data(contentsOf: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id))

        let result = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()
        let after = try Data(contentsOf: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id))

        XCTAssertNotEqual(before, newer)
        XCTAssertFalse(result.allowed)
        XCTAssertEqual(after, newer)
    }

    func testRepeatedHydrationRemainsIdempotent() async throws {
        let fixture = try makeFixture()
        try fixture.store.deleteSession(id: fixture.session.id, propertyID: fixture.property.id)

        let first = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()
        let firstData = try Data(contentsOf: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id))
        let second = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()
        let secondData = try Data(contentsOf: fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id))

        XCTAssertTrue(first.allowed)
        XCTAssertTrue(second.allowed)
        XCTAssertEqual(first.hydratedShotCount, second.hydratedShotCount)
        XCTAssertEqual(firstData, secondData)
    }
}
