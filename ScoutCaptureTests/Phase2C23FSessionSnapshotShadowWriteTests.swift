import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C23FSessionSnapshotShadowWriteTests: XCTestCase {
    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C23F-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults(shadowWriteEnabled: Bool = true) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C23F-\(UUID().uuidString)") ?? .standard
        defaults.set(shadowWriteEnabled, forKey: "session_snapshot_shadow_write_enabled")
        return defaults
    }

    private func makeFixture(
        shadowWriteEnabled: Bool = true,
        storageUploadOverride: AppState.SessionSnapshotStorageUploadOverride? = nil,
        rowInsertOverride: AppState.SessionSnapshotRowInsertOverride? = nil,
        rowsFetchOverride: AppState.SessionSnapshotRowsFetchOverride? = nil,
        storageDownloadOverride: AppState.SessionSnapshotStorageDownloadOverride? = nil,
        clientAuthPreflightOverride: (() async -> (userID: String, email: String, error: String))? = nil,
        remoteParentPreflightOverride: ((UUID, UUID, UUID) async throws -> AppState.SessionSnapshotAuthPreflightRemoteParentStatus)? = nil
    ) throws -> (store: LocalStore, appState: AppState, root: URL, property: Property, session: Session) {
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let property = try store.createProperty(Property(id: UUID(), orgId: UUID(), name: "Snapshot Upload Property"))
        let session = try store.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                exportedAt: Date(timeIntervalSinceReferenceDate: 250),
                isSealed: true,
                firstDeliveredAt: Date(timeIntervalSinceReferenceDate: 300),
                reExportExpiresAt: Date(timeIntervalSinceReferenceDate: 400)
            )
        )
        try saveMetadata(store: store, property: property, session: session)
        let appState = AppState(
            localStore: store,
            userDefaults: makeDefaults(shadowWriteEnabled: shadowWriteEnabled),
            environment: [
                "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
                "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key"
            ],
            sessionSnapshotStorageUploadOverride: storageUploadOverride ?? { _ in },
            sessionSnapshotRowInsertOverride: rowInsertOverride ?? { _ in },
            sessionSnapshotRowsFetchOverride: rowsFetchOverride,
            sessionSnapshotStorageDownloadOverride: storageDownloadOverride,
            sessionSnapshotClientAuthPreflightOverride: clientAuthPreflightOverride,
            sessionSnapshotRemoteParentPreflightOverride: remoteParentPreflightOverride,
            disableCloudBackupForTests: true
        )
        appState.selectedPropertyID = property.id
        return (store, appState, root, property, session)
    }

    private func saveMetadata(store: LocalStore, property: Property, session: Session) throws {
        let shot = ShotMetadata(
            shotID: UUID(),
            propertyID: property.id,
            sessionID: session.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 150),
            updatedAt: Date(timeIntervalSinceReferenceDate: 160),
            building: "Building",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            trade: "Paint",
            priority: "high",
            shotKey: ShotMetadata.makeShotKey(building: "Building", elevation: "North", detailType: "Overview", angleIndex: 1),
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: "missing.heic",
            originalRelativePath: "Originals/missing.heic",
            originalByteSize: 4,
            storageBucket: "scoutcapture-originals",
            storagePath: "sessions/session-id/shots/shot-id/missing.heic",
            checksumSHA256: String(repeating: "a", count: 64),
            byteSize: 4,
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
        let metadata = SessionMetadata(
            schemaVersion: 12,
            propertyID: property.id,
            sessionID: session.id,
            orgID: property.orgId,
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
            issues: [IssueMetadata(issueID: UUID(), currentReason: "Peeling paint")],
            guidedShots: [GuidedShot(title: "North overview", building: "Building", targetElevation: "North", detailType: "Overview", angleIndex: 1)]
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)
    }

    func testFeatureFlagDefaultsOff() {
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C23F-default-\(UUID().uuidString)") ?? .standard
        let flags = BackendFeatureFlags.load(userDefaults: defaults)

        XCTAssertFalse(flags.sessionSnapshotShadowWriteEnabled)
    }

    func testDisabledFlagPreventsUpload() async throws {
        var storageCalled = false
        var rowCalled = false
        let fixture = try makeFixture(
            shadowWriteEnabled: false,
            storageUploadOverride: { _ in storageCalled = true },
            rowInsertOverride: { _ in rowCalled = true }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(result.outcome, .disabled)
        XCTAssertFalse(storageCalled)
        XCTAssertFalse(rowCalled)
    }

    func testUploadPathConstruction() {
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let snapshotID = UUID()

        let path = AppState.sessionSnapshotStoragePath(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            snapshotKind: .completed,
            snapshotID: snapshotID
        )

        XCTAssertEqual(
            path,
            "orgs/\(orgID.uuidString.lowercased())/properties/\(propertyID.uuidString.lowercased())/sessions/\(sessionID.uuidString.lowercased())/snapshots/completed/\(snapshotID.uuidString.lowercased()).json"
        )
    }

    func testPayloadChecksumMetadataMatchesPreview() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let generatedAt = Date(timeIntervalSinceReferenceDate: 800)

        let preview = fixture.appState.inspectSessionSnapshotPreview(
            inspectedAt: generatedAt,
            trigger: "manual_diagnostic"
        )
        let artifacts = try fixture.appState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            snapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            kind: .manual,
            trigger: "manual_diagnostic",
            generatedAt: generatedAt
        )

        let envelope = try XCTUnwrap(preview.rows.first?.envelope)
        XCTAssertEqual(artifacts.object.bucket, "scoutcapture-session-snapshots")
        XCTAssertEqual(artifacts.object.payloadSHA256, envelope.snapshotPayloadSHA256)
        XCTAssertEqual(artifacts.row.snapshotPayloadSHA256, envelope.snapshotPayloadSHA256)
        XCTAssertEqual(artifacts.row.rawSessionJSONSHA256, envelope.rawSessionJSONSHA256)
        XCTAssertEqual(artifacts.row.payloadByteSize, envelope.snapshotPayloadByteCount)
    }

    func testStorageAndTableSuccessRecordsSuccess() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.successCount, 1)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.orphanRiskCount, 0)
        XCTAssertTrue(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastUploadPath?.isEmpty == false)
        XCTAssertTrue(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastStorageUploadCompleted)
        XCTAssertTrue(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastRowInsertCompleted)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastUploadOutcome, "succeeded")
        XCTAssertNil(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastUploadErrorMessage)
    }

    func testManualAuthPreflightRecordsReadyStateWhenUsersAndParentsMatch() async throws {
        let userID = UUID()
        let fixture = try makeFixture(
            clientAuthPreflightOverride: {
                (userID: userID.uuidString, email: "debug@example.com", error: "none")
            },
            remoteParentPreflightOverride: { _, _, _ in
                return AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    orgIDsMatch: true,
                    errorMessage: nil
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: fixture.property.orgId,
            authenticatedUserID: userID
        )

        let result = await fixture.appState.refreshManualSessionSnapshotAuthPreflight(
            checkedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )

        XCTAssertTrue(result.isReady)
        XCTAssertEqual(result.appAuthUserID, userID.uuidString.lowercased())
        XCTAssertEqual(result.clientAuthUserID, userID.uuidString.lowercased())
        XCTAssertTrue(result.usersMatch)
        XCTAssertEqual(result.payloadOrgID, fixture.property.orgId)
        XCTAssertEqual(result.payloadPropertyID, fixture.property.id)
        XCTAssertEqual(result.payloadSessionID, fixture.session.id)
        XCTAssertEqual(
            fixture.appState.localDiagnostics.sessionSnapshotUpload.lastAuthPreflightReady,
            true,
            "diagnostics=\(fixture.appState.localDiagnostics.sessionSnapshotUpload)"
        )
        XCTAssertTrue(fixture.appState.manualSessionSnapshotUploadAvailability.isAvailable)
    }

    func testManualAuthPreflightMismatchDisablesManualUploadAvailabilityWithoutUploading() async throws {
        let appUserID = UUID()
        let clientUserID = UUID()
        var storageCalled = false
        let fixture = try makeFixture(
            storageUploadOverride: { _ in storageCalled = true },
            clientAuthPreflightOverride: {
                (userID: clientUserID.uuidString, email: "client@example.com", error: "none")
            },
            remoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    orgIDsMatch: true,
                    errorMessage: nil
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: fixture.property.orgId,
            authenticatedUserID: appUserID
        )

        let result = await fixture.appState.refreshManualSessionSnapshotAuthPreflight()

        XCTAssertFalse(result.isReady)
        XCTAssertFalse(result.usersMatch)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastAuthPreflightReady, false)
        XCTAssertTrue(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastAuthPreflightFailureMessage?.contains("app_client_auth_user_mismatch") == true)
        XCTAssertFalse(
            fixture.appState.manualSessionSnapshotUploadAvailability.isAvailable,
            "diagnostics=\(fixture.appState.localDiagnostics.sessionSnapshotUpload) availability=\(fixture.appState.manualSessionSnapshotUploadAvailability)"
        )
        XCTAssertTrue(fixture.appState.manualSessionSnapshotUploadAvailability.reason.contains("auth preflight not ready"))
        XCTAssertFalse(storageCalled)
    }

    func testUploadBlockedBeforeStorageWhenRemoteParentOrgMismatchWasConfirmed() async throws {
        let canonicalOrgID = UUID()
        var storageCalled = false
        var rowCalled = false
        let fixture = try makeFixture(
            storageUploadOverride: { _ in storageCalled = true },
            rowInsertOverride: { _ in rowCalled = true },
            remoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: canonicalOrgID,
                    sessionOrgID: canonicalOrgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = await fixture.appState.refreshManualSessionSnapshotAuthPreflight()
        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message?.contains("remote parent org mismatch") == true)
        XCTAssertFalse(storageCalled)
        XCTAssertFalse(rowCalled)
        XCTAssertNil(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastSnapshotID)
        XCTAssertNil(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastUploadPath)
        XCTAssertFalse(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastStorageUploadCompleted)
    }

    func testSelectedLocalOrgRepairUpdatesOnlySelectedPropertyAndSessionMetadata() async throws {
        let canonicalOrgID = UUID()
        let otherOrgID = UUID()
        let fixture = try makeFixture(
            remoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: canonicalOrgID,
                    sessionOrgID: canonicalOrgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.store.createOrganization(Organization(id: otherOrgID, name: "Other Org"))
        let otherProperty = try fixture.store.createProperty(
            Property(id: UUID(), orgId: otherOrgID, name: "Other Property")
        )
        let otherSession = try fixture.store.upsertSession(
            Session(
                id: UUID(),
                propertyID: otherProperty.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 300),
                status: .completed
            )
        )
        try saveMetadata(store: fixture.store, property: otherProperty, session: otherSession)

        let result = await fixture.appState.repairSelectedManualSessionSnapshotLocalOrgDrift()

        XCTAssertTrue(result.repaired)
        XCTAssertEqual(result.previousLocalOrgID, fixture.property.orgId)
        XCTAssertEqual(result.canonicalOrgID, canonicalOrgID)
        let repairedProperty = try XCTUnwrap(try fixture.store.fetchProperties().first { $0.id == fixture.property.id })
        let untouchedProperty = try XCTUnwrap(try fixture.store.fetchProperties().first { $0.id == otherProperty.id })
        let repairedMetadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)
        let untouchedMetadata = try fixture.store.loadSessionMetadata(propertyID: otherProperty.id, sessionID: otherSession.id)
        XCTAssertEqual(repairedProperty.orgId, canonicalOrgID)
        XCTAssertEqual(repairedMetadata.orgID, canonicalOrgID)
        XCTAssertEqual(untouchedProperty.orgId, otherOrgID)
        XCTAssertEqual(untouchedMetadata.orgID, otherOrgID)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastLocalOrgRepairOutcome, "repaired")
    }

    func testSelectedLocalOrgRepairBlockedWhenCanonicalRemoteOrgCannotBeConfirmed() async throws {
        let originalOrgID: UUID
        let fixture = try makeFixture(
            remoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: UUID(),
                    sessionOrgID: UUID(),
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        originalOrgID = try XCTUnwrap(fixture.property.orgId)

        let result = await fixture.appState.repairSelectedManualSessionSnapshotLocalOrgDrift()

        XCTAssertFalse(result.repaired)
        XCTAssertTrue(result.message.contains("could not be confirmed"))
        let property = try XCTUnwrap(try fixture.store.fetchProperties().first { $0.id == fixture.property.id })
        let metadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)
        XCTAssertEqual(property.orgId, originalOrgID)
        XCTAssertEqual(metadata.orgID, originalOrgID)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastLocalOrgRepairOutcome, "blocked")
    }

    func testStorageSuccessTableInsertFailureRecordsOrphanRisk() async throws {
        let fixture = try makeFixture(rowInsertOverride: { _ in
            throw NSError(domain: "ScoutCaptureTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "insert failed"
            ])
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(result.outcome, .orphanRisk)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.orphanRiskCount, 1)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.failureCount, 1)
        XCTAssertTrue(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastUploadPath?.isEmpty == false)
        XCTAssertTrue(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastStorageUploadCompleted)
        XCTAssertFalse(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastRowInsertCompleted)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastUploadOutcome, "orphanRisk")
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastUploadErrorMessage, "insert failed")
    }

    func testMissingRemoteBucketOrTableReportsUnavailableWithoutCrash() async throws {
        let fixture = try makeFixture(storageUploadOverride: { _ in
            throw AppState.SessionSnapshotUploadError.remoteUnavailable("missing bucket scoutcapture-session-snapshots")
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(result.outcome, .unavailable)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.remoteAvailability, "unavailable")
        XCTAssertTrue(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastUploadPath?.isEmpty == false)
        XCTAssertFalse(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastStorageUploadCompleted)
        XCTAssertFalse(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastRowInsertCompleted)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastUploadOutcome, "unavailable")
        XCTAssertEqual(
            fixture.appState.localDiagnostics.sessionSnapshotUpload.lastUploadErrorMessage,
            "Session snapshot remote table or bucket is unavailable: missing bucket scoutcapture-session-snapshots"
        )
    }

    func testUploadReportIsSanitized() async throws {
        let fixture = try makeFixture(storageUploadOverride: { _ in
            throw NSError(domain: "ScoutCaptureTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "failed /private/tmp/session.json token=abc https://example.supabase.co/signed?token=secret data:image/png;base64,abcdef"
            ])
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let report = AppState.sessionSnapshotUploadReportText(fixture.appState.localDiagnostics.sessionSnapshotUpload)

        XCTAssertFalse(report.contains("/private/tmp"))
        XCTAssertFalse(report.contains("token=abc"))
        XCTAssertFalse(report.contains("https://example.supabase.co"))
        XCTAssertFalse(report.contains("data:image/png"))
        XCTAssertFalse(report.contains("rawSessionJSON"))
        XCTAssertTrue(report.contains("generated_payload_path_present"))
        XCTAssertTrue(report.contains("storage_upload_completed"))
        XCTAssertTrue(report.contains("row_insert_completed"))
        XCTAssertTrue(report.contains("final_upload_outcome"))
        XCTAssertTrue(report.contains("last_upload_error"))
        XCTAssertTrue(report.contains("does not switch canonical reads"))
    }

    func testUploadFailureReturnsResultAndDoesNotThrowOrBlockCaller() async throws {
        let fixture = try makeFixture(rowInsertOverride: { _ in
            throw NSError(domain: "ScoutCaptureTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "table insert failed"
            ])
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            kind: .manual,
            trigger: "manual_diagnostic"
        )

        XCTAssertEqual(result.outcome, .orphanRisk)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.failureCount, 1)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastUploadOutcome, "orphanRisk")
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastUploadErrorMessage, "table insert failed")
    }

    func testReadbackRowObjectConsistencyAndChecksumVerification() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let artifacts = try fixture.appState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            snapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000124")!,
            kind: .manual,
            trigger: "manual_diagnostic"
        )
        let result = AppState.makeSessionSnapshotReadbackResult(
            row: artifacts.row,
            payloadData: artifacts.object.payloadData,
            checkedAt: Date(timeIntervalSinceReferenceDate: 900),
            failureReason: nil
        )

        XCTAssertEqual(result.status, "verified")
        XCTAssertTrue(result.rowFound)
        XCTAssertTrue(result.payloadReadable)
        XCTAssertTrue(result.checksumVerified)
        XCTAssertTrue(result.byteSizeMatches)
        XCTAssertTrue(result.countsValid)
        XCTAssertTrue(result.rowObjectConsistent)
        XCTAssertEqual(result.payloadByteSize, artifacts.row.payloadByteSize)
    }

    func testReadbackExistingRowMissingObjectIsDiagnosticOnly() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let artifacts = try fixture.appState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let result = AppState.makeSessionSnapshotReadbackResult(
            row: artifacts.row,
            payloadData: nil,
            checkedAt: Date(timeIntervalSinceReferenceDate: 901),
            failureReason: "object missing"
        )

        XCTAssertEqual(result.status, "payload_unreadable")
        XCTAssertTrue(result.rowFound)
        XCTAssertFalse(result.payloadReadable)
        XCTAssertFalse(result.checksumVerified)
        XCTAssertFalse(result.rowObjectConsistent)
        XCTAssertEqual(result.failureReason, "object missing")
    }

    func testReadbackExistingObjectMissingRowIsDiagnosticOnly() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let artifacts = try fixture.appState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let result = AppState.makeSessionSnapshotReadbackResult(
            row: nil,
            payloadData: artifacts.object.payloadData,
            checkedAt: Date(timeIntervalSinceReferenceDate: 902),
            failureReason: "row missing"
        )

        XCTAssertEqual(result.status, "row_missing")
        XCTAssertFalse(result.rowFound)
        XCTAssertTrue(result.payloadReadable)
        XCTAssertFalse(result.checksumVerified)
        XCTAssertFalse(result.rowObjectConsistent)
    }

    func testReadbackPayloadFailureRemainsNonBlockingAndSanitized() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let artifacts = try fixture.appState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let readbackFixture = try makeFixture(
            rowsFetchOverride: { _, _, _ in [artifacts.row] },
            storageDownloadOverride: { _, _ in
                throw NSError(domain: "ScoutCaptureTests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "download failed /private/tmp/session.json token=abc https://example.supabase.co/signed?token=secret"
                ])
            }
        )
        defer { try? FileManager.default.removeItem(at: readbackFixture.root) }

        let result = await readbackFixture.appState.validateLatestSessionSnapshotRemoteReadback()
        let diagnostics = readbackFixture.appState.localDiagnostics.sessionSnapshotUpload
        let report = AppState.sessionSnapshotUploadReportText(diagnostics)

        XCTAssertEqual(result.status, "payload_unreadable")
        XCTAssertEqual(diagnostics.lastReadbackStatus, "payload_unreadable")
        XCTAssertEqual(diagnostics.failureCount, 0)
        XCTAssertFalse(report.contains("/private/tmp"))
        XCTAssertFalse(report.contains("token=abc"))
        XCTAssertFalse(report.contains("https://example.supabase.co"))
        XCTAssertTrue(report.contains("Remote Readback"))
    }
}
