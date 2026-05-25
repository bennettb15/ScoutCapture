import XCTest
import CryptoKit
@testable import ScoutCapture

@MainActor
final class Phase2C25BSnapshotRestoreDiagnosticsTests: XCTestCase {
    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C25B-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let hostedStagingURL = "https://hpekjqqiyurrewfjvjmn.supabase.co"

    private func makeDefaults(supabaseEnabled: Bool = false) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C25B-\(UUID().uuidString)") ?? .standard
        defaults.set(supabaseEnabled, forKey: "supabase_enabled")
        defaults.set(true, forKey: "session_snapshot_shadow_write_enabled")
        return defaults
    }

    private func localEnvironment() -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key"
        ]
    }

    private func approvedStagingEnvironment() -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": hostedStagingURL,
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "staging-anon-key"
        ]
    }

    private func approvedStagingEnvironment(anonKey: String) -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": hostedStagingURL,
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": anonKey
        ]
    }

    private func productionEnvironment() -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": "https://chlvazmtucoszicehtnm.supabase.co",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "production-anon-key",
            "SCOUTCAPTURE_PRODUCTION_SNAPSHOT_VALIDATION_ALLOWED": "true"
        ]
    }

    private func randomRemoteEnvironment() -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": "https://example.supabase.co",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "remote-anon-key"
        ]
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeFixture(
        generatedAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        rowTransform: ((AppState.SessionSnapshotUploadRow) -> AppState.SessionSnapshotUploadRow)? = nil,
        objectTransform: ((AppState.SessionSnapshotStorageObject) -> AppState.SessionSnapshotStorageObject)? = nil,
        environment: [String: String]? = nil,
        rowsOverride: AppState.SessionSnapshotRowsFetchOverride? = nil,
        downloadOverride: AppState.SessionSnapshotStorageDownloadOverride? = nil,
        mediaDownloadOverride: AppState.SessionSnapshotMediaDownloadOverride? = nil,
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
            environment: environment ?? localEnvironment(),
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
            environment: environment ?? localEnvironment(),
            sessionSnapshotRowsFetchOverride: rowsOverride ?? { _, _, _ in [row] },
            sessionSnapshotStorageDownloadOverride: downloadOverride ?? { _, _ in object.payloadData },
            sessionSnapshotMediaDownloadOverride: mediaDownloadOverride,
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
        checksumSHA256: String? = String(repeating: "a", count: 64),
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
            checksumSHA256: checksumSHA256,
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

    private func stagingValidationHeaderValue(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw XCTSkip("Set \(key) to run hosted staging media recovery validation.")
        }
        return value
    }

    @discardableResult
    private func performStagingRESTRequest(
        path: String,
        method: String,
        serviceKey: String,
        body: Data,
        contentType: String
    ) async throws -> Data {
        guard let url = URL(string: "\(hostedStagingURL)\(path)") else {
            XCTFail("Invalid staging URL path: \(path)")
            return Data()
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        request.setValue(serviceKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if method != "GET" {
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        }
        if path.hasPrefix("/storage/v1/object/") {
            request.setValue("false", forHTTPHeaderField: "x-upsert")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            XCTFail("Missing HTTP response for staging request \(path)")
            return Data()
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            XCTFail("Staging request failed: \(method) \(path) status=\(http.statusCode) body=\(bodyText)")
            return Data()
        }
        return data
    }

    private func insertStagingRow(
        table: String,
        payload: [String: Any],
        serviceKey: String
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try await performStagingRESTRequest(
            path: "/rest/v1/\(table)",
            method: "POST",
            serviceKey: serviceKey,
            body: data,
            contentType: "application/json"
        )
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
    }

    func testMediaRetrievalGuardrailsAllowWhenPolicyInputsPass() {
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

        XCTAssertEqual(violations, [])
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
        XCTAssertTrue(report.contains("media_retrieval_blocked_reasons: manual_operator_confirmation_required, production_wide_retrieval_blocked"))
        XCTAssertFalse(report.contains(fixture.row.payloadStoragePath))
    }

    func testSnapshotMediaRetrievalSucceedsForLocalAndApprovedStaging() async throws {
        let bytes = Data([9, 8, 7, 6])
        let checksum = sha256Hex(bytes)

        for environment in [localEnvironment(), approvedStagingEnvironment()] {
            var mediaDownloads = 0
            let fixture = try makeFixture(
                environment: environment,
                mediaDownloadOverride: { _, _ in
                    mediaDownloads += 1
                    return bytes
                },
                mediaSetup: { _, property, session in
                    [
                        self.makeShot(
                            propertyID: property.id,
                            sessionID: session.id,
                            filename: "remote-original.jpg",
                            localReference: false,
                            remoteMetadata: true,
                            checksumSHA256: checksum,
                            byteSize: bytes.count
                        )
                    ]
                }
            )

            let result = await fixture.appState.retrieveSnapshotMediaTestOnly()

            XCTAssertTrue(result.allowed)
            XCTAssertNil(result.blockedReason)
            XCTAssertEqual(result.attemptedCount, 1)
            XCTAssertEqual(result.downloadedCount, 1)
            XCTAssertEqual(result.checksumVerifiedCount, 1)
            XCTAssertEqual(result.recoveredLocalPathCount, 1)
            XCTAssertEqual(mediaDownloads, 1)
            let recovered = fixture.appState
                .sessionSnapshotRecoveredMediaDirectoryURLForDiagnostics(
                    propertyID: fixture.property.id,
                    sessionID: fixture.session.id,
                    snapshotID: fixture.row.id
                )
                .appendingPathComponent("remote-original.jpg")
            XCTAssertTrue(recovered.path.contains("/RecoveredMedia/SnapshotMedia/"))
            XCTAssertEqual(try Data(contentsOf: recovered), bytes)
            XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastMediaRetrievalDownloadedCount, 1)
        }
    }

    func testSnapshotMediaRetrievalBlocksProductionAndRandomRemote() async throws {
        let bytes = Data([1, 2, 3, 4])
        let checksum = sha256Hex(bytes)
        let production = try makeFixture(
            environment: productionEnvironment(),
            mediaDownloadOverride: { _, _ in bytes },
            mediaSetup: { _, property, session in
                [self.makeShot(propertyID: property.id, sessionID: session.id, filename: "prod.jpg", localReference: false, checksumSHA256: checksum)]
            }
        )
        let remote = try makeFixture(
            environment: randomRemoteEnvironment(),
            mediaDownloadOverride: { _, _ in bytes },
            mediaSetup: { _, property, session in
                [self.makeShot(propertyID: property.id, sessionID: session.id, filename: "remote.jpg", localReference: false, checksumSHA256: checksum)]
            }
        )

        let productionResult = await production.appState.retrieveSnapshotMediaTestOnly()
        let remoteResult = await remote.appState.retrieveSnapshotMediaTestOnly()

        XCTAssertFalse(productionResult.allowed)
        XCTAssertEqual(productionResult.blockedReason, "production_wide_retrieval_blocked")
        XCTAssertFalse(remoteResult.allowed)
        XCTAssertEqual(remoteResult.blockedReason, "allowlisted_test_only_required")
        XCTAssertEqual(productionResult.downloadedCount, 0)
        XCTAssertEqual(remoteResult.downloadedCount, 0)
    }

    func testSnapshotMediaRetrievalRejectsChecksumMismatch() async throws {
        let expected = Data([1, 1, 1, 1])
        let downloaded = Data([2, 2, 2, 2])
        let fixture = try makeFixture(
            mediaDownloadOverride: { _, _ in downloaded },
            mediaSetup: { _, property, session in
                [
                    self.makeShot(
                        propertyID: property.id,
                        sessionID: session.id,
                        filename: "mismatch.jpg",
                        localReference: false,
                        checksumSHA256: self.sha256Hex(expected),
                        byteSize: expected.count
                    )
                ]
            }
        )

        let result = await fixture.appState.retrieveSnapshotMediaTestOnly()

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.downloadedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.items.first?.status, .rejectedChecksumMismatch)
        let recovered = fixture.appState
            .sessionSnapshotRecoveredMediaDirectoryURLForDiagnostics(
                propertyID: fixture.property.id,
                sessionID: fixture.session.id,
                snapshotID: fixture.row.id
            )
            .appendingPathComponent("mismatch.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovered.path))
    }

    func testSnapshotMediaRetrievalBlocksMissingStorageMetadataAndChecksum() async throws {
        let bytes = Data([4, 3, 2, 1])
        let missingStorage = try makeFixture(
            mediaDownloadOverride: { _, _ in bytes },
            mediaSetup: { _, property, session in
                [
                    self.makeShot(
                        propertyID: property.id,
                        sessionID: session.id,
                        filename: "missing-storage.jpg",
                        localReference: false,
                        remoteMetadata: false,
                        checksumSHA256: self.sha256Hex(bytes)
                    )
                ]
            }
        )
        let missingChecksum = try makeFixture(
            mediaDownloadOverride: { _, _ in bytes },
            mediaSetup: { _, property, session in
                [
                    self.makeShot(
                        propertyID: property.id,
                        sessionID: session.id,
                        filename: "missing-checksum.jpg",
                        localReference: false,
                        remoteMetadata: true,
                        checksumSHA256: nil
                    )
                ]
            }
        )

        let storageResult = await missingStorage.appState.retrieveSnapshotMediaTestOnly()
        let checksumResult = await missingChecksum.appState.retrieveSnapshotMediaTestOnly()

        XCTAssertFalse(storageResult.allowed)
        XCTAssertEqual(storageResult.blockedReason, "missing_remote_storage_metadata")
        XCTAssertFalse(checksumResult.allowed)
        XCTAssertEqual(checksumResult.blockedReason, "checksum_unknown")
        XCTAssertEqual(storageResult.downloadedCount, 0)
        XCTAssertEqual(checksumResult.downloadedCount, 0)
    }

    func testSnapshotMediaRetrievalDoesNotOverwriteDuplicateRecoveredFile() async throws {
        let originalRecovered = Data([7, 7, 7, 7])
        let remoteBytes = Data([8, 8, 8, 8])
        var mediaDownloads = 0
        let fixture = try makeFixture(
            mediaDownloadOverride: { _, _ in
                mediaDownloads += 1
                return remoteBytes
            },
            mediaSetup: { _, property, session in
                [
                    self.makeShot(
                        propertyID: property.id,
                        sessionID: session.id,
                        filename: "duplicate.jpg",
                        localReference: false,
                        checksumSHA256: self.sha256Hex(remoteBytes),
                        byteSize: remoteBytes.count
                    )
                ]
            }
        )
        let recovered = fixture.appState
            .sessionSnapshotRecoveredMediaDirectoryURLForDiagnostics(
                propertyID: fixture.property.id,
                sessionID: fixture.session.id,
                snapshotID: fixture.row.id
            )
            .appendingPathComponent("duplicate.jpg")
        try FileManager.default.createDirectory(at: recovered.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalRecovered.write(to: recovered)

        let result = await fixture.appState.retrieveSnapshotMediaTestOnly()

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.skippedExistingCount, 1)
        XCTAssertEqual(result.downloadedCount, 0)
        XCTAssertEqual(mediaDownloads, 0)
        XCTAssertEqual(try Data(contentsOf: recovered), originalRecovered)
    }

    func testSnapshotMediaRetrievalBatchLimitEnforcedBeforeDownload() async throws {
        let bytes = Data([5])
        var mediaDownloads = 0
        let fixture = try makeFixture(
            mediaDownloadOverride: { _, _ in
                mediaDownloads += 1
                return bytes
            },
            mediaSetup: { _, property, session in
                (0..<26).map { index in
                    self.makeShot(
                        propertyID: property.id,
                        sessionID: session.id,
                        filename: "batch-\(index).jpg",
                        localReference: false,
                        checksumSHA256: self.sha256Hex(bytes),
                        byteSize: bytes.count
                    )
                }
            }
        )

        let result = await fixture.appState.retrieveSnapshotMediaTestOnly()

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "max_batch_size_exceeded")
        XCTAssertEqual(result.attemptedCount, 0)
        XCTAssertEqual(mediaDownloads, 0)
    }

    func testSnapshotMediaRetrievalDoesNotChangeMetadataHydrationOrCanonicalBehavior() async throws {
        let bytes = Data([3, 3, 3, 3])
        let fixture = try makeFixture(
            mediaDownloadOverride: { _, _ in bytes },
            mediaSetup: { _, property, session in
                [
                    self.makeShot(
                        propertyID: property.id,
                        sessionID: session.id,
                        filename: "guarded.jpg",
                        localReference: false,
                        checksumSHA256: self.sha256Hex(bytes),
                        byteSize: bytes.count
                    )
                ]
            }
        )
        let metadataBefore = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)

        _ = await fixture.appState.retrieveSnapshotMediaTestOnly()

        let metadataAfter = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)
        let recovered = fixture.appState
            .sessionSnapshotRecoveredMediaDirectoryURLForDiagnostics(
                propertyID: fixture.property.id,
                sessionID: fixture.session.id,
                snapshotID: fixture.row.id
            )
            .appendingPathComponent("guarded.jpg")
        let original = fixture.store
            .originalsFolderURL(propertyID: fixture.property.id, sessionID: fixture.session.id)
            .appendingPathComponent("guarded.jpg")
        XCTAssertEqual(metadataAfter.shots.map(\.shotID), metadataBefore.shots.map(\.shotID))
        XCTAssertTrue(recovered.path.contains("/RecoveredMedia/SnapshotMedia/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertNil(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastHydrationAt)
        XCTAssertFalse(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastHydrationAllowed)
        XCTAssertFalse(fixture.appState.localDiagnostics.sessionSnapshotUpload.productionHydrationAllowed)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.hydrationMode, "blocked_by_default")
    }

    func testPhase2C26DHostedStagingMediaRecoveryValidation() async throws {
        guard ProcessInfo.processInfo.environment["SCOUTCAPTURE_RUN_26D_STAGING_MEDIA_RECOVERY_VALIDATION"] == "1" else {
            throw XCTSkip("Set SCOUTCAPTURE_RUN_26D_STAGING_MEDIA_RECOVERY_VALIDATION=1 to run hosted staging validation.")
        }
        let serviceKey = try stagingValidationHeaderValue("SCOUTCAPTURE_26D_STAGING_SERVICE_ROLE_KEY")
        let mediaBytes = Data([0xff, 0xd8, 0xff, 0xe0, 0x32, 0x43, 0x32, 0x36, 0x44, 0xff, 0xd9])
        let mediaChecksum = sha256Hex(mediaBytes)
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let orgID = UUID()
        _ = try store.createOrganization(Organization(id: orgID, name: "Phase 2C-26D Staging Org"))
        let property = try store.createProperty(Property(
            id: UUID(),
            orgId: orgID,
            name: "Phase 2C-26D Staging Media Recovery Validation"
        ))
        let session = try store.upsertSession(Session(
            id: UUID(),
            propertyID: property.id,
            startedAt: Date(timeIntervalSinceReferenceDate: 10_000),
            status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            exportedAt: nil,
            isSealed: true,
            firstDeliveredAt: nil,
            reExportExpiresAt: nil
        ))
        let filename = "phase-2c-26d-real-media.jpg"
        let storagePath = "sessions/\(session.id.uuidString.lowercased())/\(filename)"
        let shot = makeShot(
            propertyID: property.id,
            sessionID: session.id,
            filename: filename,
            localReference: false,
            remoteMetadata: true,
            checksumSHA256: mediaChecksum,
            byteSize: mediaBytes.count
        )
        try saveMetadata(store: store, property: property, session: session, orgID: orgID, shots: [shot])

        let iso8601 = ISO8601DateFormatter()
        try await insertStagingRow(
            table: "orgs",
            payload: [
                "id": orgID.uuidString.lowercased(),
                "name": "Phase 2C-26D Staging Org"
            ],
            serviceKey: serviceKey
        )
        try await insertStagingRow(
            table: "properties",
            payload: [
                "id": property.id.uuidString.lowercased(),
                "org_id": orgID.uuidString.lowercased(),
                "name": property.name
            ],
            serviceKey: serviceKey
        )
        try await insertStagingRow(
            table: "sessions",
            payload: [
                "id": session.id.uuidString.lowercased(),
                "org_id": orgID.uuidString.lowercased(),
                "property_id": property.id.uuidString.lowercased(),
                "status": session.status.rawValue,
                "started_at": iso8601.string(from: session.startedAt),
                "completed_at": session.endedAt.map { iso8601.string(from: $0) } ?? NSNull()
            ],
            serviceKey: serviceKey
        )
        try await performStagingRESTRequest(
            path: "/storage/v1/object/scoutcapture-originals/\(storagePath)",
            method: "POST",
            serviceKey: serviceKey,
            body: mediaBytes,
            contentType: "image/jpeg"
        )

        let artifactAppState = AppState(
            localStore: store,
            userDefaults: makeDefaults(),
            environment: localEnvironment(),
            disableCloudBackupForTests: true
        )

        let snapshotID = UUID()
        let loadedMetadata = try store.loadSessionMetadata(propertyID: property.id, sessionID: session.id)
        XCTAssertEqual(loadedMetadata.shots.count, 1)
        let snapshotArtifacts = try artifactAppState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: property.id,
            sessionID: session.id,
            snapshotID: snapshotID,
            kind: .manual,
            trigger: "phase_2c_26d_hosted_staging_validation",
            generatedAt: Date()
        )
        XCTAssertEqual(snapshotArtifacts.row.mediaManifestCount, 1)
        XCTAssertEqual(snapshotArtifacts.row.manifest.media.count, 1)
        let validatedSnapshotRow = AppState.SessionSnapshotUploadRow(
            id: snapshotID,
            orgID: orgID,
            propertyID: property.id,
            sessionID: session.id,
            snapshotKind: snapshotArtifacts.row.snapshotKind,
            snapshotSchemaVersion: snapshotArtifacts.row.snapshotSchemaVersion,
            sessionMetadataSchemaVersion: snapshotArtifacts.row.sessionMetadataSchemaVersion,
            trigger: snapshotArtifacts.row.trigger,
            sessionStatus: snapshotArtifacts.row.sessionStatus,
            isSealed: snapshotArtifacts.row.isSealed,
            exportedAt: snapshotArtifacts.row.exportedAt,
            firstDeliveredAt: snapshotArtifacts.row.firstDeliveredAt,
            reExportExpiresAt: snapshotArtifacts.row.reExportExpiresAt,
            payloadStorageBucket: snapshotArtifacts.row.payloadStorageBucket,
            payloadStoragePath: snapshotArtifacts.row.payloadStoragePath,
            payloadByteSize: snapshotArtifacts.row.payloadByteSize,
            rawSessionJSONSHA256: snapshotArtifacts.row.rawSessionJSONSHA256,
            snapshotPayloadSHA256: snapshotArtifacts.row.snapshotPayloadSHA256,
            manifest: snapshotArtifacts.row.manifest,
            shotCount: snapshotArtifacts.row.shotCount,
            issueCount: snapshotArtifacts.row.issueCount,
            guidedCount: snapshotArtifacts.row.guidedCount,
            mediaManifestCount: snapshotArtifacts.row.mediaManifestCount,
            missingLocalOriginalsCount: snapshotArtifacts.row.missingLocalOriginalsCount,
            supabaseStorageMetadataCount: snapshotArtifacts.row.supabaseStorageMetadataCount,
            createdBy: snapshotArtifacts.row.createdBy,
            updatedBy: snapshotArtifacts.row.updatedBy,
            createdAt: snapshotArtifacts.row.createdAt
        )
        try await performStagingRESTRequest(
            path: "/storage/v1/object/\(snapshotArtifacts.object.bucket)/\(snapshotArtifacts.object.path)",
            method: "POST",
            serviceKey: serviceKey,
            body: snapshotArtifacts.object.payloadData,
            contentType: snapshotArtifacts.object.contentType
        )
        let rowEncoder = JSONEncoder()
        rowEncoder.dateEncodingStrategy = .iso8601
        let rowData = try rowEncoder.encode(snapshotArtifacts.row)
        try await performStagingRESTRequest(
            path: "/rest/v1/session_snapshots",
            method: "POST",
            serviceKey: serviceKey,
            body: rowData,
            contentType: "application/json"
        )
        print("[Phase2C26D] seeded_snapshot snapshot_id=\(snapshotID.uuidString) storage_path=\(snapshotArtifacts.object.path)")

        let rowFetchOverride: AppState.SessionSnapshotRowsFetchOverride = { requestedSnapshotID, requestedPropertyID, requestedSessionID in
            let requestedContext = [
                requestedSnapshotID.map { "requested_snapshot=\($0.uuidString.lowercased())" },
                requestedPropertyID.map { "requested_property=\($0.uuidString.lowercased())" },
                requestedSessionID.map { "requested_session=\($0.uuidString.lowercased())" }
            ].compactMap { $0 }.joined(separator: ",")
            let filters = [
                "select=*",
                "id=eq.\(snapshotID.uuidString.lowercased())"
            ]
            let data = try await self.performStagingRESTRequest(
                path: "/rest/v1/session_snapshots?\(filters.joined(separator: "&"))",
                method: "GET",
                serviceKey: serviceKey,
                body: Data(),
                contentType: "application/json"
            )
            let rawRows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let remoteRow = rawRows.first
            XCTAssertEqual(remoteRow?["id"] as? String, snapshotID.uuidString.lowercased())
            XCTAssertEqual(remoteRow?["org_id"] as? String, orgID.uuidString.lowercased())
            XCTAssertEqual(remoteRow?["property_id"] as? String, property.id.uuidString.lowercased())
            XCTAssertEqual(remoteRow?["session_id"] as? String, session.id.uuidString.lowercased())
            XCTAssertEqual(remoteRow?["payload_storage_path"] as? String, snapshotArtifacts.object.path)
            print("[Phase2C26D] row_fetch filters=\(filters.joined(separator: ",")) rows=\(rawRows.count) \(requestedContext)")
            return rawRows.isEmpty ? [] : [validatedSnapshotRow]
        }
        let parentPreflightOverride: (UUID, UUID, UUID) async throws -> AppState.SessionSnapshotAuthPreflightRemoteParentStatus = { requestedOrgID, requestedPropertyID, requestedSessionID in
            let propertyData = try await self.performStagingRESTRequest(
                path: "/rest/v1/properties?select=id,org_id&id=eq.\(property.id.uuidString.lowercased())",
                method: "GET",
                serviceKey: serviceKey,
                body: Data(),
                contentType: "application/json"
            )
            let sessionData = try await self.performStagingRESTRequest(
                path: "/rest/v1/sessions?select=id,org_id,property_id&id=eq.\(session.id.uuidString.lowercased())",
                method: "GET",
                serviceKey: serviceKey,
                body: Data(),
                contentType: "application/json"
            )
            let propertyRows = (try JSONSerialization.jsonObject(with: propertyData) as? [[String: Any]]) ?? []
            let sessionRows = (try JSONSerialization.jsonObject(with: sessionData) as? [[String: Any]]) ?? []
            let propertyOrgID = (propertyRows.first?["org_id"] as? String).flatMap(UUID.init(uuidString:))
            let sessionOrgID = (sessionRows.first?["org_id"] as? String).flatMap(UUID.init(uuidString:))
            let sessionPropertyID = (sessionRows.first?["property_id"] as? String).flatMap(UUID.init(uuidString:))
            let propertyMatches = sessionPropertyID == property.id
            print("[Phase2C26D] parent_preflight property_rows=\(propertyRows.count) session_rows=\(sessionRows.count) property_org=\(propertyOrgID?.uuidString ?? "nil") session_org=\(sessionOrgID?.uuidString ?? "nil") session_property=\(sessionPropertyID?.uuidString ?? "nil") requested_org=\(requestedOrgID.uuidString) requested_property=\(requestedPropertyID.uuidString) requested_session=\(requestedSessionID.uuidString)")
            return AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                propertyExists: propertyRows.first != nil,
                sessionExists: sessionRows.first != nil,
                propertyOrgID: propertyOrgID,
                sessionOrgID: sessionOrgID,
                sessionPropertyIDMatches: propertyMatches,
                orgIDsMatch: propertyOrgID == orgID && sessionOrgID == orgID && propertyMatches,
                errorMessage: nil
            )
        }
        let seededSnapshotBucket = snapshotArtifacts.object.bucket
        let seededSnapshotPath = snapshotArtifacts.object.path
        let seededMediaBucket = "scoutcapture-originals"
        let seededMediaPath = storagePath
        let snapshotDownloadOverride: AppState.SessionSnapshotStorageDownloadOverride = { _, _ in
            try await self.performStagingRESTRequest(
                path: "/storage/v1/object/\(seededSnapshotBucket)/\(seededSnapshotPath)",
                method: "GET",
                serviceKey: serviceKey,
                body: Data(),
                contentType: "application/json"
            )
        }
        let mediaDownloadOverride: AppState.SessionSnapshotMediaDownloadOverride = { _, _ in
            try await self.performStagingRESTRequest(
                path: "/storage/v1/object/\(seededMediaBucket)/\(seededMediaPath)",
                method: "GET",
                serviceKey: serviceKey,
                body: Data(),
                contentType: "application/json"
            )
        }
        let appState = AppState(
            localStore: store,
            userDefaults: makeDefaults(supabaseEnabled: true),
            environment: approvedStagingEnvironment(anonKey: serviceKey),
            sessionSnapshotRowsFetchOverride: rowFetchOverride,
            sessionSnapshotStorageDownloadOverride: snapshotDownloadOverride,
            sessionSnapshotMediaDownloadOverride: mediaDownloadOverride,
            sessionSnapshotRemoteParentPreflightOverride: parentPreflightOverride,
            disableCloudBackupForTests: true
        )
        appState.selectedPropertyID = property.id
        appState.currentSession = session

        let diagnostics = await appState.validateLatestSessionSnapshotRestoreDiagnostics()
        print("[Phase2C26D] diagnostics result=\(diagnostics.result.rawValue) failure=\(diagnostics.failureReason ?? "none") row_found=\(diagnostics.rowFound) object_readable=\(diagnostics.objectReadable) media_manifest=\(diagnostics.mediaRecoveryDiagnostics.manifestCount) recoverable_remote=\(diagnostics.mediaRecoveryDiagnostics.recoverableRemoteCount)")
        guard diagnostics.result == .restorableMetadataCandidate else {
            XCTFail("Expected hosted staging restore diagnostics to be restorable, got \(diagnostics.result.rawValue): \(diagnostics.failureReason ?? "no failure reason")")
            return
        }
        XCTAssertTrue(diagnostics.rowObjectVerified)
        XCTAssertTrue(diagnostics.checksumVerified)
        XCTAssertTrue(diagnostics.parentRemoteVerified)
        XCTAssertEqual(diagnostics.mediaRecoveryDiagnostics.recoverableRemoteCount, 1)
        XCTAssertEqual(diagnostics.mediaRecoveryDiagnostics.readiness, "ready")

        let firstRetrieval = await appState.retrieveSnapshotMediaTestOnly()
        let recovered = appState
            .sessionSnapshotRecoveredMediaDirectoryURLForDiagnostics(
                propertyID: property.id,
                sessionID: session.id,
                snapshotID: snapshotID
            )
            .appendingPathComponent(filename)
        let original = store
            .originalsFolderURL(propertyID: property.id, sessionID: session.id)
            .appendingPathComponent(filename)

        XCTAssertTrue(firstRetrieval.allowed)
        XCTAssertNil(firstRetrieval.blockedReason)
        XCTAssertEqual(firstRetrieval.attemptedCount, 1)
        XCTAssertEqual(firstRetrieval.downloadedCount, 1)
        XCTAssertEqual(firstRetrieval.checksumVerifiedCount, firstRetrieval.downloadedCount)
        XCTAssertEqual(firstRetrieval.failedCount, 0)
        XCTAssertEqual(firstRetrieval.recoveredLocalPathCount, firstRetrieval.downloadedCount)
        XCTAssertTrue(recovered.path.contains("/RecoveredMedia/SnapshotMedia/\(snapshotID.uuidString.lowercased())/"))
        XCTAssertEqual(try Data(contentsOf: recovered), mediaBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))

        let recoveredBeforeDuplicateRun = try Data(contentsOf: recovered)
        let duplicateRetrieval = await appState.retrieveSnapshotMediaTestOnly()

        XCTAssertTrue(duplicateRetrieval.allowed)
        XCTAssertEqual(duplicateRetrieval.attemptedCount, 1)
        XCTAssertEqual(duplicateRetrieval.downloadedCount, 0)
        XCTAssertEqual(duplicateRetrieval.skippedExistingCount, 1)
        XCTAssertEqual(duplicateRetrieval.failedCount, 0)
        XCTAssertEqual(try Data(contentsOf: recovered), recoveredBeforeDuplicateRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))

        print("[Phase2C26D] staging_url=\(hostedStagingURL)")
        print("[Phase2C26D] property_id=\(property.id.uuidString)")
        print("[Phase2C26D] session_id=\(session.id.uuidString)")
        print("[Phase2C26D] snapshot_id=\(snapshotID.uuidString)")
        print("[Phase2C26D] storage_object=scoutcapture-originals/\(storagePath)")
        print("[Phase2C26D] snapshot_object=\(snapshotArtifacts.object.path)")
        print("[Phase2C26D] retrieval allowed=\(firstRetrieval.allowed) attempted=\(firstRetrieval.attemptedCount) downloaded=\(firstRetrieval.downloadedCount) checksum_verified=\(firstRetrieval.checksumVerifiedCount) failed=\(firstRetrieval.failedCount) recovered_paths=\(firstRetrieval.recoveredLocalPathCount)")
        print("[Phase2C26D] duplicate allowed=\(duplicateRetrieval.allowed) attempted=\(duplicateRetrieval.attemptedCount) downloaded=\(duplicateRetrieval.downloadedCount) skipped_existing=\(duplicateRetrieval.skippedExistingCount) failed=\(duplicateRetrieval.failedCount)")
        print("[Phase2C26D] recovered_path=\(recovered.path)")
    }
}
