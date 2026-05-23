import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C25BSnapshotRestoreDiagnosticsTests: XCTestCase {
    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C25B-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C25B-\(UUID().uuidString)") ?? .standard
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
        objectTransform: ((AppState.SessionSnapshotStorageObject) -> AppState.SessionSnapshotStorageObject)? = nil,
        rowsOverride: AppState.SessionSnapshotRowsFetchOverride? = nil,
        downloadOverride: AppState.SessionSnapshotStorageDownloadOverride? = nil,
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
        _ = try store.createOrganization(Organization(id: orgID, name: "Restore Diagnostics Org"))
        let property = try store.createProperty(Property(id: UUID(), orgId: orgID, name: "Restore Diagnostics Property"))
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
        let object = objectTransform?(artifacts.object) ?? artifacts.object
        let appState = AppState(
            localStore: store,
            userDefaults: makeDefaults(),
            environment: localEnvironment(),
            sessionSnapshotRowsFetchOverride: rowsOverride ?? { _, _, _ in [row] },
            sessionSnapshotStorageDownloadOverride: downloadOverride ?? { _, _ in object.payloadData },
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
            shots: [],
            issues: [],
            guidedShots: []
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)
    }

    func testVerifiedSnapshotBecomesRestorableMetadataCandidate() async throws {
        let fixture = try makeFixture()

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.result, .restorableMetadataCandidate)
        XCTAssertTrue(result.rowFound)
        XCTAssertTrue(result.objectReadable)
        XCTAssertTrue(result.checksumVerified)
        XCTAssertTrue(result.byteSizeMatches)
        XCTAssertTrue(result.rowObjectVerified)
        XCTAssertTrue(result.parentRemoteVerified)
        XCTAssertEqual(result.localShotCount, 0)
        XCTAssertEqual(result.snapshotShotCount, 0)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastRestoreDiagnosticsResult, "restorable_metadata_candidate")
    }

    func testNoSnapshotFoundBlocksRestoreCandidate() async throws {
        let fixture = try makeFixture(rowsOverride: { _, _, _ in [] })

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.result, .noSnapshotFound)
        XCTAssertFalse(result.rowFound)
    }

    func testChecksumMismatchBlocksRestoreCandidate() async throws {
        let fixture = try makeFixture(rowTransform: { row in
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
        })

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.result, .checksumFailed)
        XCTAssertFalse(result.checksumVerified)
    }

    func testMissingObjectBlocksRestoreCandidate() async throws {
        var downloadAttempted = false
        let fixture = try makeFixture(downloadOverride: { _, _ in
            downloadAttempted = true
            throw AppState.SessionSnapshotUploadError.remoteUnavailable("secret/storage/path")
        })

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertTrue(downloadAttempted)
        XCTAssertEqual(result.result, .objectMissing)
        XCTAssertFalse(result.objectReadable)
    }

    func testParentMismatchBlocksRestoreCandidate() async throws {
        let fixture = try makeFixture(parentOverride: { _, _, _ in
            AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                propertyExists: true,
                sessionExists: true,
                propertyOrgID: UUID(),
                sessionOrgID: UUID(),
                sessionPropertyIDMatches: false,
                orgIDsMatch: false,
                errorMessage: nil
            )
        })

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.result, .parentMismatch)
        XCTAssertFalse(result.parentRemoteVerified)
    }

    func testUnsupportedSchemaBlocksRestoreCandidate() async throws {
        let fixture = try makeFixture(rowTransform: { row in
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
        })

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.result, .unsupportedSchema)
        XCTAssertEqual(result.snapshotSchemaVersion, 99)
    }

    func testLocalNewerConflictBlocksRestoreCandidate() async throws {
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

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.result, .localNewerConflict)
        XCTAssertEqual(result.freshness, "local_newer")
    }

    func testDiagnosticsReportIsSanitized() async throws {
        let fixture = try makeFixture(downloadOverride: { _, _ in
            throw AppState.SessionSnapshotUploadError.remoteUnavailable("secret/storage/path/token")
        })

        _ = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()
        let report = AppState.sessionSnapshotUploadReportText(fixture.appState.localDiagnostics.sessionSnapshotUpload)

        XCTAssertTrue(report.contains("Snapshot Restore Diagnostics"))
        XCTAssertFalse(report.contains("secret/storage/path/token"))
        XCTAssertFalse(report.contains(fixture.row.payloadStoragePath))
        XCTAssertFalse(report.contains(String(data: fixture.object.payloadData, encoding: .utf8) ?? ""))
    }

    func testRestoreDiagnosticsDoNotWriteLocalMetadata() async throws {
        let fixture = try makeFixture()
        let sessionJSONURL = fixture.store.sessionJSONURL(propertyID: fixture.property.id, sessionID: fixture.session.id)
        let before = try Data(contentsOf: sessionJSONURL)

        _ = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        let after = try Data(contentsOf: sessionJSONURL)
        XCTAssertEqual(before, after)
    }
}
