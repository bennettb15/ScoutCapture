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
        propertyID: UUID = UUID(),
        propertyOrgID: UUID = UUID(),
        sessionID: UUID = UUID(),
        storageUploadOverride: AppState.SessionSnapshotStorageUploadOverride? = nil,
        rowInsertOverride: AppState.SessionSnapshotRowInsertOverride? = nil,
        rowsFetchOverride: AppState.SessionSnapshotRowsFetchOverride? = nil,
        storageDownloadOverride: AppState.SessionSnapshotStorageDownloadOverride? = nil,
        clientAuthPreflightOverride: (() async -> (userID: String, email: String, error: String))? = nil,
        remoteParentPreflightOverride: ((UUID, UUID, UUID) async throws -> AppState.SessionSnapshotAuthPreflightRemoteParentStatus)? = nil
    ) throws -> (store: LocalStore, appState: AppState, root: URL, property: Property, session: Session) {
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let property = try store.createProperty(Property(id: propertyID, orgId: propertyOrgID, name: "Snapshot Upload Property"))
        let session = try store.upsertSession(
            Session(
                id: sessionID,
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

    private func writeRawSessionMetadata(
        _ metadata: SessionMetadata,
        store: LocalStore,
        propertyID: UUID,
        sessionID: UUID
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: store.sessionJSONURL(propertyID: propertyID, sessionID: sessionID), options: .atomic)
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

    func testStaleLocalPropertyOrgOverridesSessionMetadataOrgDuringLoad() throws {
        let root = try makeTempStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(testStorageRootURL: root)
        let propertyOrgID = UUID()
        let metadataOrgID = UUID()
        _ = try store.createOrganization(Organization(id: propertyOrgID, name: "Property Org"))
        let property = try store.createProperty(
            Property(id: UUID(), orgId: propertyOrgID, name: "Stale Boundary Property")
        )
        let session = try store.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .completed
            )
        )
        var metadata = try store.loadSessionMetadata(propertyID: property.id, sessionID: session.id)
        metadata.orgID = metadataOrgID
        try writeRawSessionMetadata(metadata, store: store, propertyID: property.id, sessionID: session.id)

        let loaded = try store.loadSessionMetadata(propertyID: property.id, sessionID: session.id)

        XCTAssertEqual(property.orgId, propertyOrgID)
        XCTAssertEqual(loaded.orgID, propertyOrgID)
        XCTAssertNotEqual(loaded.orgID, metadataOrgID)
    }

    func testConfirmedRemoteParentResultProvidesCanonicalOrg() {
        let canonicalOrgID = UUID()
        let unconfirmedStatuses = [
            AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                propertyExists: false,
                sessionExists: true,
                propertyOrgID: canonicalOrgID,
                sessionOrgID: canonicalOrgID,
                sessionPropertyIDMatches: true,
                orgIDsMatch: false,
                errorMessage: nil
            ),
            AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                propertyExists: true,
                sessionExists: false,
                propertyOrgID: canonicalOrgID,
                sessionOrgID: canonicalOrgID,
                sessionPropertyIDMatches: true,
                orgIDsMatch: false,
                errorMessage: nil
            ),
            AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                propertyExists: true,
                sessionExists: true,
                propertyOrgID: canonicalOrgID,
                sessionOrgID: UUID(),
                sessionPropertyIDMatches: true,
                orgIDsMatch: false,
                errorMessage: nil
            ),
            AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                propertyExists: true,
                sessionExists: true,
                propertyOrgID: canonicalOrgID,
                sessionOrgID: canonicalOrgID,
                sessionPropertyIDMatches: false,
                orgIDsMatch: false,
                errorMessage: nil
            )
        ]
        let confirmed = AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
            propertyExists: true,
            sessionExists: true,
            propertyOrgID: canonicalOrgID,
            sessionOrgID: canonicalOrgID,
            sessionPropertyIDMatches: true,
            orgIDsMatch: false,
            errorMessage: nil
        )

        XCTAssertEqual(confirmed.confirmedCanonicalOrgID, canonicalOrgID)
        XCTAssertTrue(confirmed.hasConfirmedRemoteParent)
        for status in unconfirmedStatuses {
            XCTAssertNil(status.confirmedCanonicalOrgID)
            XCTAssertFalse(status.hasConfirmedRemoteParent)
        }
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

    func testSelectedLocalOrgRepairSurvivesPropertySyncEventProjection() async throws {
        let userID = UUID()
        let canonicalOrgID = UUID()
        let fixture = try makeFixture(
            clientAuthPreflightOverride: {
                (userID: userID.uuidString, email: "debug@example.com", error: "none")
            },
            remoteParentPreflightOverride: { orgID, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: canonicalOrgID,
                    sessionOrgID: canonicalOrgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: orgID == canonicalOrgID,
                    errorMessage: nil
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: canonicalOrgID,
            authenticatedUserID: userID
        )

        let initialPreflight = await fixture.appState.refreshManualSessionSnapshotAuthPreflight()
        XCTAssertFalse(initialPreflight.isReady)
        XCTAssertEqual(initialPreflight.remoteParentStatus.propertyOrgID, canonicalOrgID)
        XCTAssertEqual(initialPreflight.remoteParentStatus.sessionOrgID, canonicalOrgID)
        XCTAssertTrue(initialPreflight.remoteParentStatus.sessionPropertyIDMatches)
        XCTAssertFalse(initialPreflight.remoteParentStatus.orgIDsMatch)
        XCTAssertTrue(initialPreflight.failureMessage?.contains("remote_parent_org_mismatch") == true)

        _ = await fixture.appState.repairSelectedManualSessionSnapshotLocalOrgDrift()

        let projectedProperty = try XCTUnwrap(try fixture.store.fetchProperties().first { $0.id == fixture.property.id })
        let projectedMetadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)
        XCTAssertEqual(projectedProperty.orgId, canonicalOrgID)
        XCTAssertEqual(projectedMetadata.orgID, canonicalOrgID)
        let refreshedPreflight = await fixture.appState.refreshManualSessionSnapshotAuthPreflight()
        XCTAssertEqual(refreshedPreflight.payloadOrgID, canonicalOrgID)
        XCTAssertTrue(refreshedPreflight.usersMatch, refreshedPreflight.failureMessage ?? "users did not match")
        XCTAssertTrue(refreshedPreflight.remoteParentStatus.orgIDsMatch, refreshedPreflight.failureMessage ?? "remote orgs did not match")
        XCTAssertTrue(refreshedPreflight.isReady)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastAuthPreflightReady, true)
        XCTAssertNil(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastAuthPreflightFailureMessage)

        let audit = await fixture.appState.runLocalOrgDriftAudit()
        XCTAssertEqual(audit.propertyMismatchCount, 0)
        XCTAssertEqual(audit.sessionMismatchCount, 0)
        XCTAssertEqual(audit.unableToConfirmCount, 0)
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

    func testSelectedLocalOrgRepairRefusesUnconfirmedRemoteParentRows() async throws {
        let canonicalOrgID = UUID()
        let mismatchedOrgID = UUID()
        let cases: [(String, AppState.SessionSnapshotAuthPreflightRemoteParentStatus)] = [
            (
                "property_missing_or_hidden",
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: false,
                    sessionExists: true,
                    propertyOrgID: canonicalOrgID,
                    sessionOrgID: canonicalOrgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            ),
            (
                "session_missing_or_hidden",
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: false,
                    propertyOrgID: canonicalOrgID,
                    sessionOrgID: canonicalOrgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            ),
            (
                "remote_orgs_disagree",
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: canonicalOrgID,
                    sessionOrgID: mismatchedOrgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            ),
            (
                "session_belongs_to_another_property",
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: canonicalOrgID,
                    sessionOrgID: canonicalOrgID,
                    sessionPropertyIDMatches: false,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            )
        ]

        for (name, status) in cases {
            let fixture = try makeFixture(
                remoteParentPreflightOverride: { _, _, _ in status }
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let originalOrgID = try XCTUnwrap(fixture.property.orgId, name)

            let result = await fixture.appState.repairSelectedManualSessionSnapshotLocalOrgDrift()

            XCTAssertFalse(result.repaired, name)
            XCTAssertTrue(result.message.contains("could not be confirmed"), name)
            let property = try XCTUnwrap(try fixture.store.fetchProperties().first { $0.id == fixture.property.id }, name)
            let metadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)
            XCTAssertEqual(property.orgId, originalOrgID, name)
            XCTAssertEqual(metadata.orgID, originalOrgID, name)
            XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastLocalOrgRepairOutcome, "blocked", name)
        }
    }

    func testLocalOrgDriftAuditDetectsPropertyAndSessionMetadataMismatches() async throws {
        let canonicalOrgID = UUID()
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

        let result = await fixture.appState.runLocalOrgDriftAudit()

        XCTAssertEqual(result.totalPropertiesChecked, 1)
        XCTAssertEqual(result.totalSessionsChecked, 1)
        XCTAssertEqual(result.propertyMismatchCount, 1)
        XCTAssertEqual(result.sessionMismatchCount, 1)
        XCTAssertEqual(result.unableToConfirmCount, 0)
        XCTAssertEqual(result.samples.count, 2)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastLocalOrgDriftAuditPropertyMismatchCount, 1)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastLocalOrgDriftAuditSessionMismatchCount, 1)
    }

    func testLocalOrgDriftAuditRequiresCanonicalRemoteAgreement() async throws {
        let canonicalOrgID = UUID()
        let mismatchedOrgID = UUID()
        let cases: [(String, AppState.SessionSnapshotAuthPreflightRemoteParentStatus)] = [
            (
                "remote_orgs_disagree",
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: canonicalOrgID,
                    sessionOrgID: mismatchedOrgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            ),
            (
                "session_belongs_to_another_property",
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: canonicalOrgID,
                    sessionOrgID: canonicalOrgID,
                    sessionPropertyIDMatches: false,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            )
        ]

        for (name, status) in cases {
            let fixture = try makeFixture(
                remoteParentPreflightOverride: { _, _, _ in status }
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            let result = await fixture.appState.runLocalOrgDriftAudit()

            XCTAssertEqual(result.totalPropertiesChecked, 0, name)
            XCTAssertEqual(result.totalSessionsChecked, 0, name)
            XCTAssertEqual(result.propertyMismatchCount, 0, name)
            XCTAssertEqual(result.sessionMismatchCount, 0, name)
            XCTAssertEqual(result.unableToConfirmCount, 1, name)
            XCTAssertTrue(result.samples.isEmpty, name)
        }
    }

    func testLocalOrgDriftAuditTreatsMissingOrHiddenRemoteRowsAsUnableToConfirm() async throws {
        let localOrgID = UUID()
        let cases: [(String, AppState.SessionSnapshotAuthPreflightRemoteParentStatus)] = [
            (
                "property_missing_or_hidden",
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: false,
                    sessionExists: true,
                    propertyOrgID: nil,
                    sessionOrgID: localOrgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            ),
            (
                "session_missing_or_hidden",
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: false,
                    propertyOrgID: localOrgID,
                    sessionOrgID: nil,
                    sessionPropertyIDMatches: false,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            )
        ]

        for (name, status) in cases {
            let fixture = try makeFixture(
                remoteParentPreflightOverride: { _, _, _ in status }
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            let result = await fixture.appState.runLocalOrgDriftAudit()

            XCTAssertEqual(result.totalPropertiesChecked, 0, name)
            XCTAssertEqual(result.totalSessionsChecked, 0, name)
            XCTAssertEqual(result.totalMismatchCount, 0, name)
            XCTAssertEqual(result.unableToConfirmCount, 1, name)
            XCTAssertTrue(result.samples.isEmpty, name)
        }
    }

    func testLocalOrgDriftAuditDoesNotReportFalsePositiveWhenLocalMatchesCanonical() async throws {
        let localOrgID = UUID()
        let fixture = try makeFixture(
            remoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: localOrgID,
                    sessionOrgID: localOrgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: true,
                    errorMessage: nil
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.store.createOrganization(Organization(id: localOrgID, name: "Canonical Org"))
        var property = fixture.property
        property.orgId = localOrgID
        _ = try fixture.store.updateProperty(property)
        var metadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)
        metadata.orgID = localOrgID
        try fixture.store.saveSessionMetadataAtomically(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            metadata: metadata
        )

        let result = await fixture.appState.runLocalOrgDriftAudit()

        XCTAssertEqual(result.totalPropertiesChecked, 1)
        XCTAssertEqual(result.totalSessionsChecked, 1)
        XCTAssertEqual(result.totalMismatchCount, 0)
        XCTAssertEqual(result.unableToConfirmCount, 0)
        XCTAssertTrue(result.samples.isEmpty)
    }

    func testConfirmedLocalOrgDriftRepairRepairsPropertyAndSessionMetadataCounts() async throws {
        let canonicalOrgID = UUID()
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

        let repair = await fixture.appState.repairConfirmedLocalOrgDrift()

        XCTAssertEqual(repair.attemptedCount, 2)
        XCTAssertEqual(repair.repairedPropertyCount, 1)
        XCTAssertEqual(repair.repairedSessionCount, 1)
        XCTAssertEqual(repair.skippedCount, 0)
        XCTAssertEqual(repair.failureCount, 0)
        let property = try XCTUnwrap(try fixture.store.fetchProperties().first { $0.id == fixture.property.id })
        let metadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)
        XCTAssertEqual(property.orgId, canonicalOrgID)
        XCTAssertEqual(metadata.orgID, canonicalOrgID)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastLocalOrgDriftRepairPropertyCount, 1)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastLocalOrgDriftRepairSessionCount, 1)
    }

    func testConfirmedLocalOrgDriftRepairSkipsUnableToConfirmAndUnrelatedItems() async throws {
        let localOrgID = UUID()
        let fixture = try makeFixture(
            propertyOrgID: localOrgID,
            remoteParentPreflightOverride: { _, propertyID, _ in
                return AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: false,
                    sessionExists: true,
                    propertyOrgID: nil,
                    sessionOrgID: UUID(),
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalProperty = try XCTUnwrap(try fixture.store.fetchProperties().first { $0.id == fixture.property.id })
        let originalMetadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)

        let repair = await fixture.appState.repairConfirmedLocalOrgDrift()

        XCTAssertEqual(repair.attemptedCount, 0)
        XCTAssertEqual(repair.repairedPropertyCount, 0)
        XCTAssertEqual(repair.repairedSessionCount, 0)
        XCTAssertEqual(repair.skippedCount, 1)
        XCTAssertEqual(repair.failureCount, 0)
        let untouchedProperty = try XCTUnwrap(try fixture.store.fetchProperties().first { $0.id == fixture.property.id })
        let untouchedMetadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)
        XCTAssertEqual(untouchedProperty.orgId, originalProperty.orgId)
        XCTAssertEqual(untouchedMetadata.orgID, originalMetadata.orgID)
    }

    func testConfirmedLocalOrgDriftRepairSkipsConflictingRemoteParents() async throws {
        let canonicalOrgID = UUID()
        let mismatchedOrgID = UUID()
        let fixture = try makeFixture(
            remoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: canonicalOrgID,
                    sessionOrgID: mismatchedOrgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: false,
                    errorMessage: nil
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalOrgID = fixture.property.orgId

        let repair = await fixture.appState.repairConfirmedLocalOrgDrift()

        XCTAssertEqual(repair.attemptedCount, 0)
        XCTAssertEqual(repair.repairedPropertyCount, 0)
        XCTAssertEqual(repair.repairedSessionCount, 0)
        XCTAssertEqual(repair.skippedCount, 1)
        XCTAssertEqual(repair.failureCount, 0)
        let property = try XCTUnwrap(try fixture.store.fetchProperties().first { $0.id == fixture.property.id })
        let metadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)
        XCTAssertEqual(property.orgId, originalOrgID)
        XCTAssertEqual(metadata.orgID, originalOrgID)
    }

    func testSecondAuditAfterConfirmedLocalOrgDriftRepairShowsNoConfirmedDrift() async throws {
        let canonicalOrgID = UUID()
        let fixture = try makeFixture(
            remoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: canonicalOrgID,
                    sessionOrgID: canonicalOrgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: true,
                    errorMessage: nil
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = await fixture.appState.repairConfirmedLocalOrgDrift()
        let projectedProperty = try XCTUnwrap(try fixture.store.fetchProperties().first { $0.id == fixture.property.id })
        let projectedMetadata = try fixture.store.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.session.id)
        let audit = await fixture.appState.runLocalOrgDriftAudit()

        XCTAssertEqual(projectedProperty.orgId, canonicalOrgID)
        XCTAssertEqual(projectedMetadata.orgID, canonicalOrgID)
        XCTAssertEqual(audit.totalPropertiesChecked, 1)
        XCTAssertEqual(audit.totalSessionsChecked, 1)
        XCTAssertEqual(audit.propertyMismatchCount, 0)
        XCTAssertEqual(audit.sessionMismatchCount, 0)
        XCTAssertEqual(audit.unableToConfirmCount, 0)
        XCTAssertTrue(audit.confirmedMismatches.isEmpty)
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
