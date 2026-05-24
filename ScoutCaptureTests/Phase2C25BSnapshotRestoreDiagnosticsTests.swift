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
        parentOverride: ((UUID, UUID, UUID) async throws -> AppState.SessionSnapshotAuthPreflightRemoteParentStatus)? = nil,
        mediaSetup: ((LocalStore, Property, Session) throws -> [ShotMetadata])? = nil
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
        let shots = try mediaSetup?(store, property, session) ?? []
        try saveMetadata(store: store, property: property, session: session, orgID: orgID, shots: shots)

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

    private func saveMetadata(
        store: LocalStore,
        property: Property,
        session: Session,
        orgID: UUID,
        shots: [ShotMetadata] = []
    ) throws {
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
            shots: shots,
            issues: [],
            guidedShots: []
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)
    }

    private func makeShot(
        propertyID: UUID,
        sessionID: UUID,
        filename: String,
        localReference: Bool = true,
        remoteMetadata: Bool = true,
        byteSize: Int = 4
    ) -> ShotMetadata {
        ShotMetadata(
            shotID: UUID(),
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 120),
            updatedAt: Date(timeIntervalSinceReferenceDate: 130),
            building: "A",
            elevation: "North",
            detailType: filename,
            angleIndex: 1,
            shotKey: "a-north-\(filename)-1",
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: filename,
            originalRelativePath: localReference ? "Originals/\(filename)" : "",
            originalByteSize: byteSize,
            storageBucket: remoteMetadata ? "scoutcapture-originals" : nil,
            storagePath: remoteMetadata ? "sessions/\(sessionID.uuidString.lowercased())/\(filename)" : nil,
            checksumSHA256: String(repeating: "a", count: 64),
            byteSize: byteSize,
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
    }

    private func writeOriginal(_ store: LocalStore, propertyID: UUID, sessionID: UUID, filename: String, bytes: [UInt8] = [1, 2, 3, 4]) throws {
        let folder = store.originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(bytes).write(to: folder.appendingPathComponent(filename, isDirectory: false))
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

    func testMediaRecoveryDiagnosticsAllRecoverableFromRemoteMetadata() async throws {
        let fixture = try makeFixture(mediaSetup: { _, property, session in
            [
                self.makeShot(propertyID: property.id, sessionID: session.id, filename: "remote-1.jpg", localReference: true, remoteMetadata: true),
                self.makeShot(propertyID: property.id, sessionID: session.id, filename: "remote-2.jpg", localReference: true, remoteMetadata: true)
            ]
        })

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.mediaRecoveryDiagnostics.manifestCount, 2)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.recoverableRemoteCount, 2)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.recoverableLocalCount, 0)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.missingCount, 0)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.readiness, "ready")
        XCTAssertEqual(result.mediaRecoveryDiagnostics.planningState, .remoteOnly)
    }

    func testMediaRecoveryDiagnosticsAllRecoverableFromLocalCache() async throws {
        let fixture = try makeFixture(mediaSetup: { store, property, session in
            try self.writeOriginal(store, propertyID: property.id, sessionID: session.id, filename: "local-1.jpg")
            try self.writeOriginal(store, propertyID: property.id, sessionID: session.id, filename: "local-2.jpg")
            return [
                self.makeShot(propertyID: property.id, sessionID: session.id, filename: "local-1.jpg", remoteMetadata: false),
                self.makeShot(propertyID: property.id, sessionID: session.id, filename: "local-2.jpg", remoteMetadata: false)
            ]
        })

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.mediaRecoveryDiagnostics.recoverableRemoteCount, 0)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.recoverableLocalCount, 2)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.localFilesPresentCount, 2)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.missingCount, 0)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.readiness, "ready")
        XCTAssertEqual(result.mediaRecoveryDiagnostics.planningState, .localOnly)
    }

    func testMediaRecoveryDiagnosticsMixedLocalAndRemoteRecovery() async throws {
        let fixture = try makeFixture(mediaSetup: { store, property, session in
            try self.writeOriginal(store, propertyID: property.id, sessionID: session.id, filename: "local.jpg")
            return [
                self.makeShot(propertyID: property.id, sessionID: session.id, filename: "remote.jpg", remoteMetadata: true),
                self.makeShot(propertyID: property.id, sessionID: session.id, filename: "local.jpg", remoteMetadata: false)
            ]
        })

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.mediaRecoveryDiagnostics.recoverableRemoteCount, 1)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.recoverableLocalCount, 1)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.missingCount, 0)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.stateCounts[.recoverableFromSupabaseStorage], 1)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.stateCounts[.recoverableFromLocalCache], 1)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.planningState, .fullyRecoverable)
    }

    func testMediaRecoveryDiagnosticsMissingRemoteMetadata() async throws {
        let fixture = try makeFixture(mediaSetup: { _, property, session in
            [
                self.makeShot(propertyID: property.id, sessionID: session.id, filename: "missing-remote.jpg", remoteMetadata: false)
            ]
        })

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.mediaRecoveryDiagnostics.remoteStorageMetadataPresentCount, 0)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.missingRemoteStorageMetadataCount, 1)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.missingCount, 1)
    }

    func testMediaRecoveryDiagnosticsMissingLocalFile() async throws {
        let fixture = try makeFixture(mediaSetup: { _, property, session in
            [
                self.makeShot(propertyID: property.id, sessionID: session.id, filename: "missing-local.jpg", remoteMetadata: true)
            ]
        })

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.mediaRecoveryDiagnostics.localFilesPresentCount, 0)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.missingLocalFileCount, 1)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.recoverableRemoteCount, 1)
    }

    func testMediaRecoveryDiagnosticsMissingBoth() async throws {
        let fixture = try makeFixture(mediaSetup: { _, property, session in
            [
                self.makeShot(propertyID: property.id, sessionID: session.id, filename: "missing-both.jpg", remoteMetadata: false)
            ]
        })

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.mediaRecoveryDiagnostics.missingCount, 1)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.stateCounts[.missingBoth], 1)
        XCTAssertEqual(result.mediaRecoveryDiagnostics.readiness, "partial")
        XCTAssertEqual(result.mediaRecoveryDiagnostics.planningState, .metadataOnly)
    }

    func testUnsupportedManifestBlocksMediaRecoveryReadiness() async throws {
        let fixture = try makeFixture(
            rowTransform: { row in
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
            },
            mediaSetup: { _, property, session in
                [self.makeShot(propertyID: property.id, sessionID: session.id, filename: "unsupported.jpg")]
            }
        )

        let result = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(result.mediaRecoveryDiagnostics.readiness, "unsupported_media_manifest")
        XCTAssertEqual(result.mediaRecoveryDiagnostics.planningState, .unrecoverable)
        XCTAssertFalse(result.mediaRecoveryDiagnostics.manifestSupported)
    }

    func testMediaRecoveryDiagnosticsDoNotDownloadOrWriteMedia() async throws {
        let fixture = try makeFixture(mediaSetup: { _, property, session in
            [self.makeShot(propertyID: property.id, sessionID: session.id, filename: "read-only.jpg")]
        })
        let sessionFolder = fixture.store.sessionFolderURL(propertyID: fixture.property.id, sessionID: fixture.session.id)
        let before = (try? FileManager.default.subpathsOfDirectory(atPath: sessionFolder.path)) ?? []

        _ = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()

        let after = (try? FileManager.default.subpathsOfDirectory(atPath: sessionFolder.path)) ?? []
        XCTAssertEqual(before.sorted(), after.sorted())
    }

    func testMediaRecoveryPlanningStateMapping() {
        XCTAssertEqual(
            AppState.sessionSnapshotMediaRecoveryPlanningState(
                manifestCount: 4,
                localFilesPresentCount: 2,
                remoteStorageMetadataPresentCount: 4,
                missingCount: 0,
                unsupportedCount: 0,
                checksumMismatchCount: 0
            ),
            .fullyRecoverable
        )
        XCTAssertEqual(
            AppState.sessionSnapshotMediaRecoveryPlanningState(
                manifestCount: 4,
                localFilesPresentCount: 0,
                remoteStorageMetadataPresentCount: 2,
                missingCount: 2,
                unsupportedCount: 0,
                checksumMismatchCount: 0
            ),
            .partiallyRecoverable
        )
        XCTAssertEqual(
            AppState.sessionSnapshotMediaRecoveryPlanningState(
                manifestCount: 2,
                localFilesPresentCount: 0,
                remoteStorageMetadataPresentCount: 0,
                missingCount: 2,
                unsupportedCount: 0,
                checksumMismatchCount: 0
            ),
            .metadataOnly
        )
        XCTAssertEqual(
            AppState.sessionSnapshotMediaRecoveryPlanningState(
                manifestCount: 0,
                localFilesPresentCount: 0,
                remoteStorageMetadataPresentCount: 0,
                missingCount: 0,
                unsupportedCount: 0,
                checksumMismatchCount: 0
            ),
            .unrecoverable
        )
    }

    func testMediaRetrievalGuardrailsBlockUnsafeRequests() {
        let violations = AppState.sessionSnapshotMediaRetrievalGuardrailViolations(
            requestedBatchSize: 100,
            isManual: false,
            isAllowlisted: false,
            isProductionWide: true,
            storageQuotaChecked: false,
            networkApproved: false,
            batteryApproved: false,
            checksumValidationPlanned: false,
            duplicatePreventionPlanned: false
        )

        XCTAssertTrue(violations.contains("manual_only_required"))
        XCTAssertTrue(violations.contains("allowlisted_test_only_required"))
        XCTAssertTrue(violations.contains("production_wide_retrieval_blocked"))
        XCTAssertTrue(violations.contains("max_batch_size_exceeded"))
        XCTAssertTrue(violations.contains("storage_quota_check_required"))
        XCTAssertTrue(violations.contains("network_requirement_not_met"))
        XCTAssertTrue(violations.contains("battery_requirement_not_met"))
        XCTAssertTrue(violations.contains("checksum_validation_required"))
        XCTAssertTrue(violations.contains("duplicate_prevention_required"))
        XCTAssertTrue(violations.contains("media_retrieval_not_implemented"))
    }

    func testMediaRetrievalGuardrailsRemainBlockedEvenWhenPolicyInputsPass() {
        let violations = AppState.sessionSnapshotMediaRetrievalGuardrailViolations(
            requestedBatchSize: AppState.SessionSnapshotMediaRetrievalPolicyDiagnostics.guardrailsOnly.maxBatchSize,
            isManual: true,
            isAllowlisted: true,
            isProductionWide: false,
            storageQuotaChecked: true,
            networkApproved: true,
            batteryApproved: true,
            checksumValidationPlanned: true,
            duplicatePreventionPlanned: true
        )

        XCTAssertEqual(violations, ["media_retrieval_not_implemented"])
    }

    func testMediaRecoveryGuardrailsAppearInCopyableReport() async throws {
        let fixture = try makeFixture(mediaSetup: { _, property, session in
            [self.makeShot(propertyID: property.id, sessionID: session.id, filename: "report.jpg", remoteMetadata: true)]
        })

        _ = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()
        let report = AppState.sessionSnapshotUploadReportText(fixture.appState.localDiagnostics.sessionSnapshotUpload)

        XCTAssertTrue(report.contains("media_recovery_source_priority: local_cache > icloud_local_backup > supabase_storage > export_archives"))
        XCTAssertTrue(report.contains("media_retrieval_mode: manual_only"))
        XCTAssertTrue(report.contains("media_retrieval_can_start: false"))
        XCTAssertTrue(report.contains("media_retrieval_blocked_reasons: media_retrieval_not_implemented"))
        XCTAssertFalse(report.contains(fixture.row.payloadStoragePath))
    }
}
