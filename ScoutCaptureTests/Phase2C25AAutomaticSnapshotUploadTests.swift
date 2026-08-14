import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C25AAutomaticSnapshotUploadTests: XCTestCase {
    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C25A-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults(
        shadowWriteEnabled: Bool = true,
        autoUploadEnabled: Bool = false,
        orgAllowlist: [UUID] = [],
        propertyAllowlist: [UUID] = []
    ) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ScoutCapture-2C25A-\(UUID().uuidString)") ?? .standard
        defaults.set(shadowWriteEnabled, forKey: "session_snapshot_shadow_write_enabled")
        defaults.set(autoUploadEnabled, forKey: "session_snapshot_auto_upload_enabled")
        if !orgAllowlist.isEmpty {
            defaults.set(orgAllowlist.map(\.uuidString).joined(separator: ","), forKey: "session_snapshot_auto_upload_org_allowlist")
        }
        if !propertyAllowlist.isEmpty {
            defaults.set(propertyAllowlist.map(\.uuidString).joined(separator: ","), forKey: "session_snapshot_auto_upload_property_allowlist")
        }
        return defaults
    }

    private func localEnvironment(_ extras: [String: String] = [:]) -> [String: String] {
        var environment = [
            "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key"
        ]
        extras.forEach { environment[$0.key] = $0.value }
        return environment
    }

    private func makeFixture(
        autoUploadEnabled: Bool = false,
        allowGeneratedOrg: Bool = false,
        orgAllowlist: [UUID] = [],
        propertyAllowlist: [UUID] = [],
        environmentExtras: [String: String] = [:],
        storageUploadOverride: AppState.SessionSnapshotStorageUploadOverride? = nil,
        rowInsertOverride: AppState.SessionSnapshotRowInsertOverride? = nil
    ) throws -> (store: LocalStore, appState: AppState, property: Property, session: Session, orgID: UUID) {
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let orgID = UUID()
        _ = try store.createOrganization(Organization(id: orgID, name: "Automatic Snapshot Org"))
        let property = try store.createProperty(Property(id: UUID(), orgId: orgID, name: "Automatic Snapshot Property"))
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

        let appState = AppState(
            localStore: store,
            userDefaults: makeDefaults(
                autoUploadEnabled: autoUploadEnabled,
                orgAllowlist: allowGeneratedOrg ? [orgID] : orgAllowlist,
                propertyAllowlist: propertyAllowlist
            ),
            environment: localEnvironment(environmentExtras),
            sessionSnapshotStorageUploadOverride: storageUploadOverride ?? { _ in },
            sessionSnapshotRowInsertOverride: rowInsertOverride ?? { _ in },
            disableCloudBackupForTests: true
        )
        appState.selectedPropertyID = property.id
        configureAuthenticatedContext(appState, orgID: orgID)
        return (store, appState, property, session, orgID)
    }

    private func configureAuthenticatedContext(_ appState: AppState, orgID: UUID) {
        appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: orgID,
            ready: true,
            clientConfigured: true,
            authenticated: true,
            authenticationReady: true
        )
    }

    private func saveMetadata(store: LocalStore, property: Property, session: Session, orgID: UUID) throws {
        let originalRelativePath = "Originals/test-original.heic"
        let originalURL = store.sessionFolderURL(propertyID: property.id, sessionID: session.id)
            .appendingPathComponent(originalRelativePath)
        try FileManager.default.createDirectory(
            at: originalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: originalURL, options: .atomic)
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
            isGuided: true,
            isFlagged: true,
            issueID: UUID(),
            issueStatus: "active",
            noteText: "Peeling paint",
            noteCategory: nil,
            originalFilename: "test-original.heic",
            originalRelativePath: originalRelativePath,
            originalByteSize: 4,
            storageBucket: "scoutcapture-originals",
            storagePath: "sessions/\(session.id.uuidString.lowercased())/test-original.heic",
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
            issues: [IssueMetadata(issueID: shot.issueID ?? UUID(), currentReason: "Peeling paint")],
            guidedShots: [GuidedShot(title: "North overview", building: "Building", targetElevation: "North", detailType: "Overview", angleIndex: 1)]
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)
    }

    private func waitForArchiveCount(
        store: LocalStore,
        expected: Int,
        timeout: TimeInterval = 3.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try store.fetchSessionArchiveSummaries()).count == expected {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try store.fetchSessionArchiveSummaries().count, expected, file: file, line: line)
    }

    private func waitForCloudState(
        appState: AppState,
        session: Session,
        expected: AppState.SessionSnapshotCloudState,
        timeout: TimeInterval = 3.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if appState.sessionSnapshotCloudStatus(for: session)?.state == expected {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(appState.sessionSnapshotCloudStatus(for: session)?.state, expected, file: file, line: line)
    }

    private func retryItem(
        property: Property,
        session: Session,
        orgID: UUID,
        generatedAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        triggerSource: String = "sealCurrentSessionForExportLater",
        status: LocalStore.SessionSnapshotUploadRetryWorkItem.Status = .pending,
        attemptCount: Int = 0,
        nextAttemptAt: Date? = nil
    ) -> LocalStore.SessionSnapshotUploadRetryWorkItem {
        let snapshotID = UUID()
        return LocalStore.SessionSnapshotUploadRetryWorkItem(
            snapshotID: snapshotID,
            organizationID: orgID,
            propertyID: property.id,
            sessionID: session.id,
            snapshotKind: AppState.SessionSnapshotKind.completed.rawValue,
            trigger: "auto_completed_sealed_archive:\(triggerSource)",
            triggerSource: triggerSource,
            archivePath: "/tmp/\(snapshotID.uuidString)",
            storageBucket: "session-snapshots",
            storagePath: "org/\(orgID.uuidString)/property/\(property.id.uuidString)/session/\(session.id.uuidString)/\(snapshotID.uuidString).json",
            generatedAt: generatedAt,
            sourceDeviceID: "test-device",
            idempotencyKey: "\(property.id.uuidString)|\(session.id.uuidString)|\(triggerSource)|\(generatedAt.timeIntervalSinceReferenceDate)",
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            status: status
        )
    }

    private func statusRecord(
        property: Property,
        session: Session,
        orgID: UUID,
        generatedAt: Date,
        status: LocalStore.SessionSnapshotUploadStatusRecord.Status,
        triggerSource: String = "sealCurrentSessionForExportLater",
        reason: String? = nil
    ) -> LocalStore.SessionSnapshotUploadStatusRecord {
        let snapshotID = UUID()
        return LocalStore.SessionSnapshotUploadStatusRecord(
            snapshotID: snapshotID,
            organizationID: orgID,
            propertyID: property.id,
            sessionID: session.id,
            snapshotKind: AppState.SessionSnapshotKind.completed.rawValue,
            trigger: "auto_completed_sealed_archive:\(triggerSource)",
            triggerSource: triggerSource,
            idempotencyKey: "\(property.id.uuidString)|\(session.id.uuidString)|\(triggerSource)|\(generatedAt.timeIntervalSinceReferenceDate)",
            storagePath: "org/\(orgID.uuidString)/property/\(property.id.uuidString)/session/\(session.id.uuidString)/\(snapshotID.uuidString).json",
            generatedAt: generatedAt,
            status: status,
            reason: reason,
            updatedAt: generatedAt
        )
    }

    func testAutoUploadDisabledByDefault() async throws {
        var attemptedStorageUpload = false
        let fixture = try makeFixture(
            storageUploadOverride: { _ in attemptedStorageUpload = true }
        )

        let result = await fixture.appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedStorageUpload)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.sessionSnapshotAutoUploadEnabled)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.autoUploadSkippedReason, "auto_upload_disabled")
    }

    func testEnableAloneDoesNotWorkWithoutAllowlist() async throws {
        var attemptedStorageUpload = false
        let fixture = try makeFixture(
            autoUploadEnabled: true,
            storageUploadOverride: { _ in attemptedStorageUpload = true }
        )

        let result = await fixture.appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedStorageUpload)
        XCTAssertTrue(fixture.appState.backendFeatureFlags.sessionSnapshotAutoUploadEnabled)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.autoUploadSkippedReason, "allowlist_empty")
    }

    func testEnvironmentEnableAloneDoesNotCreateAllowlist() {
        let flags = BackendFeatureFlags.load(
            userDefaults: makeDefaults(autoUploadEnabled: false),
            environment: localEnvironment(["SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_ENABLED": "true"])
        )

        XCTAssertTrue(flags.sessionSnapshotAutoUploadEnabled)
        XCTAssertFalse(flags.sessionSnapshotAutoUploadHasAllowlist)
    }

    func testEnvironmentEnableWithoutAllowlistSkipsAndRecordsEffectiveAutoFlag() async throws {
        var attemptedStorageUpload = false
        let fixture = try makeFixture(
            environmentExtras: ["SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_ENABLED": "true"],
            storageUploadOverride: { _ in attemptedStorageUpload = true }
        )

        let result = await fixture.appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedStorageUpload)
        XCTAssertTrue(fixture.appState.backendFeatureFlags.sessionSnapshotAutoUploadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.sessionSnapshotAutoUploadHasAllowlist)
        XCTAssertTrue(fixture.appState.localDiagnostics.sessionSnapshotUpload.autoUploadFlagEnabled)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.autoUploadSkippedReason, "allowlist_empty")
    }

    func testKillSwitchEnvironmentSkipsAndRecordsEffectiveKillSwitch() async throws {
        var attemptedStorageUpload = false
        let fixture = try makeFixture(
            environmentExtras: [
                "SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_ENABLED": "true",
                "SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_KILL_SWITCH": "true"
            ],
            storageUploadOverride: { _ in attemptedStorageUpload = true }
        )

        let result = await fixture.appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedStorageUpload)
        XCTAssertTrue(fixture.appState.backendFeatureFlags.sessionSnapshotAutoUploadEnabled)
        XCTAssertTrue(fixture.appState.backendFeatureFlags.sessionSnapshotAutoUploadKillSwitch)
        XCTAssertTrue(fixture.appState.localDiagnostics.sessionSnapshotUpload.autoUploadKillSwitchActive)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.autoUploadSkippedReason, "kill_switch_active")
    }

    func testKillSwitchDisablesEvenWhenFlagAndAllowlistMatch() async throws {
        var attemptedStorageUpload = false
        let fixture = try makeFixture(
            autoUploadEnabled: true,
            propertyAllowlist: [],
            environmentExtras: [
                "SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_KILL_SWITCH": "true",
                "SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_PROPERTY_ALLOWLIST": "placeholder"
            ],
            storageUploadOverride: { _ in attemptedStorageUpload = true }
        )
        let matchingDefaults = makeDefaults(
            autoUploadEnabled: true,
            propertyAllowlist: [fixture.property.id]
        )
        let matchingAppState = AppState(
            localStore: fixture.store,
            userDefaults: matchingDefaults,
            environment: localEnvironment(["SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_KILL_SWITCH": "true"]),
            sessionSnapshotStorageUploadOverride: { _ in attemptedStorageUpload = true },
            sessionSnapshotRowInsertOverride: { _ in },
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(matchingAppState, orgID: fixture.orgID)

        let result = await matchingAppState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedStorageUpload)
        XCTAssertTrue(matchingAppState.backendFeatureFlags.sessionSnapshotAutoUploadKillSwitch)
        XCTAssertEqual(matchingAppState.localDiagnostics.sessionSnapshotUpload.autoUploadSkippedReason, "kill_switch_active")
    }

    func testOrgAllowlistIsLoadedForGuardedAutoUpload() {
        let orgID = UUID()
        let flags = BackendFeatureFlags.load(
            userDefaults: makeDefaults(autoUploadEnabled: true, orgAllowlist: [orgID]),
            environment: localEnvironment()
        )

        XCTAssertTrue(flags.sessionSnapshotAutoUploadEnabled)
        XCTAssertTrue(flags.sessionSnapshotAutoUploadHasAllowlist)
        XCTAssertTrue(flags.sessionSnapshotAutoUploadOrgAllowlist.contains(orgID))
    }

    func testAllowedPropertyPermitsGuardedAutoPath() async throws {
        var insertCount = 0
        let fixture = try makeFixture(autoUploadEnabled: false)
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in },
            sessionSnapshotRowInsertOverride: { _ in insertCount += 1 },
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(appState, orgID: fixture.orgID)

        let result = await appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertEqual(result?.outcome, .succeeded)
        XCTAssertEqual(insertCount, 1)
    }

    func testNormalCompletionPathsScheduleExactlyOneArchiveSnapshot() async throws {
        let later = try makeFixture()
        later.appState.currentSession = later.session
        later.appState.sealCurrentSessionForExportLater()
        try await waitForArchiveCount(store: later.store, expected: 1)
        XCTAssertEqual(try later.store.fetchSessionArchiveSummaries().first?.trigger, "sealCurrentSessionForExportLater")

        let now = try makeFixture()
        now.appState.currentSession = now.session
        now.appState.sealCurrentSessionForExportNow()
        try await waitForArchiveCount(store: now.store, expected: 1)
        XCTAssertEqual(try now.store.fetchSessionArchiveSummaries().first?.trigger, "sealCurrentSessionForExportNow")

        let completed = try makeFixture()
        completed.appState.currentSession = completed.session
        completed.appState.completeCurrentSession(markExported: false)
        try await waitForArchiveCount(store: completed.store, expected: 1)
        XCTAssertEqual(try completed.store.fetchSessionArchiveSummaries().first?.trigger, "completeCurrentSession")

        let delivered = try makeFixture()
        delivered.appState.currentSession = delivered.session
        delivered.appState.markCurrentSessionExported()
        try await waitForArchiveCount(store: delivered.store, expected: 1)
        XCTAssertEqual(try delivered.store.fetchSessionArchiveSummaries().first?.trigger, "markCurrentSessionExported")
    }

    func testExportLaterImmediatelyUpdatesPendingExportPresentationState() async throws {
        let fixture = try makeFixture()
        fixture.appState.currentSession = fixture.session
        XCTAssertFalse(fixture.appState.propertyCardBadgeModel(for: fixture.property.id).showPendingExport)

        fixture.appState.sealCurrentSessionForExportLater()

        XCTAssertTrue(fixture.appState.isPendingDelivery(fixture.appState.currentSession ?? fixture.session))
        XCTAssertNotNil(fixture.appState.sessionSnapshotCloudStatus(for: fixture.appState.currentSession ?? fixture.session))
        XCTAssertTrue(fixture.appState.propertyCardBadgeModel(for: fixture.property.id).showPendingExport)
        XCTAssertEqual(
            fixture.appState.propertyStatusRecord(for: fixture.property.id)?.pendingExportSessionID,
            fixture.session.id
        )
        try await waitForArchiveCount(store: fixture.store, expected: 1)
        XCTAssertTrue(fixture.appState.isPendingDeliveryLocallyAvailable(fixture.appState.currentSession ?? fixture.session))
    }

    func testTransientDuplicateCachedSessionsCollapseToSingleRowIdentity() throws {
        let fixture = try makeFixture()
        fixture.appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(id: fixture.orgID, name: "Automatic Snapshot Org", role: "owner")
            ],
            activeOrganizationID: fixture.orgID,
            ready: true
        )
        fixture.appState.properties = [fixture.property]
        var duplicate = fixture.session
        duplicate.endedAt = Date(timeIntervalSinceReferenceDate: 250)
        fixture.appState._debugSetSessionCacheForTests(
            propertyID: fixture.property.id,
            sessions: [fixture.session, duplicate]
        )

        let visibleSessions = fixture.appState.sessions(for: fixture.property.id)

        XCTAssertEqual(visibleSessions.map(\.id), [fixture.session.id])
        XCTAssertEqual(visibleSessions.first?.endedAt, duplicate.endedAt)
    }

    func testExportLaterCreatesCloudStatusWhenConfigurationBlocksUpload() async throws {
        let fixture = try makeFixture(
            autoUploadEnabled: true,
            allowGeneratedOrg: true,
            environmentExtras: ["SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_KILL_SWITCH": "true"],
            storageUploadOverride: { _ in XCTFail("kill switch should block storage upload") },
            rowInsertOverride: { _ in XCTFail("kill switch should block row insert") }
        )
        fixture.appState.currentSession = fixture.session

        fixture.appState.sealCurrentSessionForExportLater()
        let scheduledStatus = try XCTUnwrap(fixture.appState.sessionSnapshotCloudStatus(for: fixture.session))
        XCTAssertEqual(scheduledStatus.state, .queued)
        XCTAssertEqual(scheduledStatus.triggerSource, "sealCurrentSessionForExportLater")

        try await waitForArchiveCount(store: fixture.store, expected: 1)
        try await waitForCloudState(appState: fixture.appState, session: fixture.session, expected: .failed)
        let blockedStatus = try XCTUnwrap(fixture.appState.sessionSnapshotCloudStatus(for: fixture.session))
        XCTAssertEqual(blockedStatus.state, .failed)
        XCTAssertTrue(try fixture.appState._debugSessionSnapshotUploadRetryWorkItemsForTests().isEmpty)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
    }

    func testExportLaterCreatesFailedCloudStatusWhenAutoUploadDisabled() throws {
        let fixture = try makeFixture(
            autoUploadEnabled: false,
            storageUploadOverride: { _ in XCTFail("disabled auto upload should not upload storage") },
            rowInsertOverride: { _ in XCTFail("disabled auto upload should not insert remote rows") }
        )
        fixture.appState.currentSession = fixture.session

        fixture.appState.sealCurrentSessionForExportLater()

        let status = try XCTUnwrap(fixture.appState.sessionSnapshotCloudStatus(for: fixture.session))
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.accessibilityLabel, "Session snapshot upload disabled")
        XCTAssertEqual(status.symbolName, "icloud.slash")
        XCTAssertEqual(status.tint, .orange)
        XCTAssertTrue(status.isConfigurationBlocked)
        XCTAssertEqual(status.sessionID, fixture.session.id)
        XCTAssertEqual(status.propertyID, fixture.property.id)
        XCTAssertEqual(status.organizationID, fixture.orgID)
        XCTAssertEqual(status.triggerSource, "sealCurrentSessionForExportLater")
        let record = try XCTUnwrap(try fixture.store.fetchSessionSnapshotUploadStatusRecords().first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.reason, "auto_upload_disabled")
        XCTAssertTrue(try fixture.appState._debugSessionSnapshotUploadRetryWorkItemsForTests().isEmpty)

        let reloaded = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: false),
            environment: localEnvironment(),
            disableCloudBackupForTests: true
        )
        let reloadedStatus = try XCTUnwrap(reloaded.sessionSnapshotCloudStatus(for: fixture.session))
        XCTAssertEqual(reloadedStatus.state, .failed)
        XCTAssertEqual(reloadedStatus.accessibilityLabel, "Session snapshot upload disabled")
        XCTAssertEqual(reloadedStatus.symbolName, "icloud.slash")
        XCTAssertEqual(reloadedStatus.tint, .orange)
    }

    func testRecentExportEligibilityAndCloudStatusCanCoexist() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        let deliveredAt = Date(timeIntervalSinceReferenceDate: 4_000)
        var exported = fixture.session
        exported.exportedAt = deliveredAt
        exported.firstDeliveredAt = deliveredAt
        exported.reExportExpiresAt = deliveredAt.addingTimeInterval(24 * 60 * 60)
        _ = try fixture.store.upsertSession(exported)
        _ = try fixture.store.upsertSessionSnapshotUploadStatusRecord(
            statusRecord(
                property: fixture.property,
                session: exported,
                orgID: fixture.orgID,
                generatedAt: deliveredAt,
                status: .uploaded,
                triggerSource: "markCurrentSessionExported"
            )
        )

        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: false),
            environment: localEnvironment(),
            disableCloudBackupForTests: true
        )
        appState.properties = [fixture.property]
        appState._debugSetSessionCacheForTests(propertyID: fixture.property.id, sessions: [exported])

        let visible = try XCTUnwrap(appState.sessions(for: fixture.property.id).first(where: { $0.id == exported.id }))
        XCTAssertTrue(appState.isReExportEligible(visible, now: deliveredAt))
        XCTAssertNotNil(appState.sessionSnapshotCloudStatus(for: visible))
        XCTAssertFalse(appState.propertyCardBadgeModel(for: fixture.property.id).showPendingExport)
    }

    func testEnteringSessionCannotPublishDuplicatePropertyRows() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        var cached = fixture.property
        cached.name = "QA Test 9.3"
        cached.updatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var refreshed = cached
        refreshed.clientName = "Surviving Client"
        refreshed.updatedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        fixture.appState.currentSession = fixture.session

        fixture.appState._debugApplyHubPresentationPayloadForTests(
            properties: [cached, refreshed],
            organizations: [Organization(id: fixture.orgID, name: "Automatic Snapshot Org")],
            sessionsByProperty: [fixture.property.id: [fixture.session]]
        )

        XCTAssertEqual(fixture.appState.properties.map(\.id), [fixture.property.id])
        XCTAssertEqual(fixture.appState.properties.first?.clientName, "Surviving Client")
        XCTAssertEqual(fixture.appState.sessions(for: fixture.property.id).map(\.id), [fixture.session.id])
    }

    func testLeavingAndReenteringSessionCannotPublishDuplicatePropertyRows() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        var older = fixture.property
        older.updatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var newer = older
        newer.address = "Newest Address"
        newer.updatedAt = Date(timeIntervalSinceReferenceDate: 2_000)

        for _ in 0..<2 {
            fixture.appState.currentSession = fixture.session
            fixture.appState._debugApplyHubPresentationPayloadForTests(
                properties: [older, newer],
                organizations: [Organization(id: fixture.orgID, name: "Automatic Snapshot Org")],
                sessionsByProperty: [fixture.property.id: [fixture.session]]
            )
            fixture.appState.clearCurrentSession()
            fixture.appState._debugApplyHubPresentationPayloadForTests(
                properties: [newer, older],
                organizations: [Organization(id: fixture.orgID, name: "Automatic Snapshot Org")],
                sessionsByProperty: [fixture.property.id: [fixture.session]]
            )

            XCTAssertEqual(fixture.appState.properties.map(\.id), [fixture.property.id])
            XCTAssertEqual(fixture.appState.properties.first?.address, "Newest Address")
        }
    }

    func testConcurrentCachedAndRefreshedPayloadsCollapseToOnePropertyRow() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        var cached = fixture.property
        cached.clientPhone = "555-0001"
        cached.updatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var refreshed = cached
        refreshed.clientPhone = "555-0002"
        refreshed.updatedAt = Date(timeIntervalSinceReferenceDate: 2_000)

        fixture.appState._debugApplyHubPresentationPayloadForTests(
            properties: [cached],
            organizations: [Organization(id: fixture.orgID, name: "Automatic Snapshot Org")],
            sessionsByProperty: [fixture.property.id: [fixture.session]]
        )
        fixture.appState._debugApplyHubPresentationPayloadForTests(
            properties: [cached, refreshed],
            organizations: [Organization(id: fixture.orgID, name: "Automatic Snapshot Org")],
            sessionsByProperty: [fixture.property.id: [fixture.session, fixture.session]]
        )

        XCTAssertEqual(fixture.appState.properties.map(\.id), [fixture.property.id])
        XCTAssertEqual(fixture.appState.properties.first?.clientPhone, "555-0002")
        XCTAssertEqual(fixture.appState.sessions(for: fixture.property.id).map(\.id), [fixture.session.id])
    }

    func testDuplicatePropertiesCollapseWithoutChangingPropertyOrdering() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        var first = try fixture.store.createProperty(Property(id: UUID(), orgId: fixture.orgID, name: "QA Test 1"))
        first.createdAt = Date(timeIntervalSinceReferenceDate: 100)
        first.updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        var second = fixture.property
        second.name = "QA Test 2"
        second.createdAt = Date(timeIntervalSinceReferenceDate: 200)
        second.updatedAt = Date(timeIntervalSinceReferenceDate: 200)
        var secondRefresh = second
        secondRefresh.clientName = "Surviving Client"
        secondRefresh.updatedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        var third = try fixture.store.createProperty(Property(id: UUID(), orgId: fixture.orgID, name: "QA Test 3"))
        third.createdAt = Date(timeIntervalSinceReferenceDate: 300)
        third.updatedAt = Date(timeIntervalSinceReferenceDate: 300)

        fixture.appState._debugApplyHubPresentationPayloadForTests(
            properties: [third, second, first, secondRefresh],
            organizations: [Organization(id: fixture.orgID, name: "Automatic Snapshot Org")],
            sessionsByProperty: [fixture.property.id: [fixture.session]]
        )

        XCTAssertEqual(fixture.appState.properties.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(fixture.appState.properties.first(where: { $0.id == second.id })?.clientName, "Surviving Client")
    }

    func testRepeatedHubPresentationRefreshPreservesPropertyOrdering() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        var first = try fixture.store.createProperty(Property(id: UUID(), orgId: fixture.orgID, name: "QA Test 1"))
        first.createdAt = Date(timeIntervalSinceReferenceDate: 100)
        first.updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        var second = fixture.property
        second.name = "QA Test 2"
        second.createdAt = Date(timeIntervalSinceReferenceDate: 200)
        second.updatedAt = Date(timeIntervalSinceReferenceDate: 200)
        var secondRefresh = second
        secondRefresh.updatedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        var third = try fixture.store.createProperty(Property(id: UUID(), orgId: fixture.orgID, name: "QA Test 3"))
        third.createdAt = Date(timeIntervalSinceReferenceDate: 300)
        third.updatedAt = Date(timeIntervalSinceReferenceDate: 300)
        let payloads = [
            [third, second, first, secondRefresh],
            [secondRefresh, third, first, second],
            [first, second, secondRefresh, third]
        ]

        for payload in payloads {
            fixture.appState._debugApplyHubPresentationPayloadForTests(
                properties: payload,
                organizations: [Organization(id: fixture.orgID, name: "Automatic Snapshot Org")],
                sessionsByProperty: [fixture.property.id: [fixture.session, fixture.session]]
            )

            XCTAssertEqual(fixture.appState.properties.map(\.id), [first.id, second.id, third.id])
            XCTAssertEqual(fixture.appState.sessions(for: fixture.property.id).map(\.id), [fixture.session.id])
        }
    }

    func testDeduplicatedPropertyRowKeepsCloudRecentAndPendingState() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        let deliveredAt = Date(timeIntervalSinceReferenceDate: 4_000)
        var exported = fixture.session
        exported.exportedAt = deliveredAt
        exported.firstDeliveredAt = deliveredAt
        exported.reExportExpiresAt = deliveredAt.addingTimeInterval(24 * 60 * 60)
        _ = try fixture.store.upsertSession(exported)
        _ = try fixture.store.upsertSessionSnapshotUploadStatusRecord(
            statusRecord(
                property: fixture.property,
                session: exported,
                orgID: fixture.orgID,
                generatedAt: deliveredAt,
                status: .uploaded,
                triggerSource: "markCurrentSessionExported"
            )
        )
        let pending = try fixture.store.upsertSession(
            Session(
                id: UUID(),
                propertyID: fixture.property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 4_500),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 4_600),
                exportedAt: nil,
                isSealed: true,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil
            )
        )
        var older = fixture.property
        older.updatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var newer = older
        newer.updatedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        var first = try fixture.store.createProperty(Property(id: UUID(), orgId: fixture.orgID, name: "QA Test 1"))
        first.createdAt = Date(timeIntervalSinceReferenceDate: 100)
        first.updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        older.createdAt = Date(timeIntervalSinceReferenceDate: 200)
        newer.createdAt = older.createdAt
        var third = try fixture.store.createProperty(Property(id: UUID(), orgId: fixture.orgID, name: "QA Test 3"))
        third.createdAt = Date(timeIntervalSinceReferenceDate: 300)
        third.updatedAt = Date(timeIntervalSinceReferenceDate: 300)

        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: false),
            environment: localEnvironment(),
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(appState, orgID: fixture.orgID)
        appState._debugApplyHubPresentationPayloadForTests(
            properties: [third, older, first, newer],
            organizations: [Organization(id: fixture.orgID, name: "Automatic Snapshot Org")],
            sessionsByProperty: [fixture.property.id: [exported, pending, pending]],
            pendingByProperty: [fixture.property.id: pending]
        )

        let survivor = try XCTUnwrap(appState.properties.first(where: { $0.id == fixture.property.id }))
        XCTAssertEqual(appState.properties.map(\.id), [first.id, fixture.property.id, third.id])
        XCTAssertEqual(survivor.updatedAt, newer.updatedAt)
        XCTAssertTrue(appState.isReExportEligible(exported, now: deliveredAt))
        XCTAssertNotNil(appState.sessionSnapshotCloudStatus(for: exported))
        XCTAssertEqual(appState.latestPendingExportSession(for: fixture.property.id)?.id, pending.id)
    }

    func testRepeatedEntryExitDoesNotNeedLaterReloadToSelfHealDuplicateRows() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        var first = fixture.property
        first.updatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var second = first
        second.updatedAt = Date(timeIntervalSinceReferenceDate: 2_000)

        for index in 0..<5 {
            fixture.appState.currentSession = fixture.session
            let payload = index.isMultiple(of: 2) ? [first, second] : [second, first, first]
            fixture.appState._debugApplyHubPresentationPayloadForTests(
                properties: payload,
                organizations: [Organization(id: fixture.orgID, name: "Automatic Snapshot Org")],
                sessionsByProperty: [fixture.property.id: [fixture.session, fixture.session]]
            )
            XCTAssertEqual(fixture.appState.properties.map(\.id), [fixture.property.id])

            fixture.appState.clearCurrentSession()
            fixture.appState._debugApplyHubPresentationPayloadForTests(
                properties: Array(payload.reversed()),
                organizations: [Organization(id: fixture.orgID, name: "Automatic Snapshot Org")],
                sessionsByProperty: [fixture.property.id: [fixture.session, fixture.session]]
            )
            XCTAssertEqual(fixture.appState.properties.map(\.id), [fixture.property.id])
            XCTAssertEqual(fixture.appState.sessions(for: fixture.property.id).map(\.id), [fixture.session.id])
        }
    }

    func testSnapshotWorkScheduledRestoresQueuedCloudState() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        _ = try fixture.store.upsertSessionSnapshotUploadRetryWorkItem(
            retryItem(property: fixture.property, session: fixture.session, orgID: fixture.orgID)
        )
        let reloaded = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            disableCloudBackupForTests: true
        )

        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.state, .queued)
        XCTAssertEqual(
            reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.accessibilityLabel,
            "Session snapshot queued"
        )
        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.symbolName, "icloud")
        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.tint, .neutral)
    }

    func testActiveUploadRestoresUploadingCloudState() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        _ = try fixture.store.upsertSessionSnapshotUploadRetryWorkItem(
            retryItem(
                property: fixture.property,
                session: fixture.session,
                orgID: fixture.orgID,
                status: .inFlight,
                attemptCount: 1
            )
        )
        let reloaded = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            disableCloudBackupForTests: true
        )

        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.state, .uploading)
        XCTAssertEqual(
            reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.accessibilityLabel,
            "Session snapshot uploading"
        )
        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.symbolName, "icloud.and.arrow.up")
        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.tint, .blue)
    }

    func testRetryableFailureRestoresRetryScheduledCloudState() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        _ = try fixture.store.upsertSessionSnapshotUploadRetryWorkItem(
            retryItem(
                property: fixture.property,
                session: fixture.session,
                orgID: fixture.orgID,
                status: .failed,
                attemptCount: 1,
                nextAttemptAt: Date(timeIntervalSinceReferenceDate: 2_000)
            )
        )
        let reloaded = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            disableCloudBackupForTests: true
        )

        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.state, .retryScheduled)
        XCTAssertEqual(
            reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.accessibilityLabel,
            "Session snapshot upload retry scheduled"
        )
        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.symbolName, "arrow.clockwise.icloud")
        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.tint, .orange)
    }

    func testTerminalFailureRestoresFailedCloudState() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        _ = try fixture.store.upsertSessionSnapshotUploadRetryWorkItem(
            retryItem(
                property: fixture.property,
                session: fixture.session,
                orgID: fixture.orgID,
                status: .terminalFailed,
                attemptCount: 1
            )
        )
        let reloaded = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            disableCloudBackupForTests: true
        )

        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.state, .failed)
        XCTAssertEqual(
            reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.accessibilityLabel,
            "Session snapshot upload failed"
        )
        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.symbolName, "exclamationmark.icloud")
        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.tint, .red)
    }

    func testConfirmedSuccessRestoresUploadedCloudState() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        _ = try fixture.store.upsertSessionSnapshotUploadStatusRecord(
            statusRecord(
                property: fixture.property,
                session: fixture.session,
                orgID: fixture.orgID,
                generatedAt: Date(timeIntervalSinceReferenceDate: 3_000),
                status: .uploaded
            )
        )
        let reloaded = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            disableCloudBackupForTests: true
        )

        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.state, .uploaded)
        XCTAssertEqual(
            reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.accessibilityLabel,
            "Session snapshot uploaded"
        )
        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.symbolName, "checkmark.icloud.fill")
        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.tint, .blue)
        XCTAssertFalse(reloaded.backendFeatureFlags.supabaseReadEnabled)
    }

    func testOlderSuccessfulCheckpointDoesNotHideNewerPendingCloudState() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        _ = try fixture.store.upsertSessionSnapshotUploadStatusRecord(
            statusRecord(
                property: fixture.property,
                session: fixture.session,
                orgID: fixture.orgID,
                generatedAt: Date(timeIntervalSinceReferenceDate: 3_000),
                status: .uploaded,
                triggerSource: "sealCurrentSessionForExportLater"
            )
        )
        _ = try fixture.store.upsertSessionSnapshotUploadRetryWorkItem(
            retryItem(
                property: fixture.property,
                session: fixture.session,
                orgID: fixture.orgID,
                generatedAt: Date(timeIntervalSinceReferenceDate: 4_000),
                triggerSource: "markCurrentSessionExported",
                status: .pending
            )
        )
        let reloaded = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            disableCloudBackupForTests: true
        )

        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.state, .queued)
        XCTAssertEqual(reloaded.sessionSnapshotCloudStatus(for: fixture.session)?.triggerSource, "markCurrentSessionExported")
    }

    func testSessionWithoutSnapshotWorkShowsNoCloudStatus() throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            disableCloudBackupForTests: true
        )

        XCTAssertNil(appState.sessionSnapshotCloudStatus(for: fixture.session))
        XCTAssertFalse(appState.backendFeatureFlags.supabaseReadEnabled)
    }

    func testCustomerSafeAutoUploadEligibilityDoesNotRequireRuntimeQAAuthorization() throws {
        let fixture = try makeFixture(
            autoUploadEnabled: true,
            propertyAllowlist: []
        )
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in },
            sessionSnapshotRowInsertOverride: { _ in },
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(appState, orgID: fixture.orgID)

        let eligibility = appState._debugSessionSnapshotAutoUploadEligibilityForTests(session: fixture.session)

        XCTAssertTrue(eligibility.allowed)
        XCTAssertEqual(eligibility.reason, "eligible")
        XCTAssertFalse(appState.backendFeatureFlags.supabaseReadEnabled)
    }

    func testFailedSnapshotUploadPersistsRetryWorkAndReloadRestoresIt() async throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in
                throw AppState.SessionSnapshotUploadError.remoteUnavailable("test bucket unavailable")
            },
            sessionSnapshotRowInsertOverride: { _ in XCTFail("row insert should not run after storage failure") },
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(appState, orgID: fixture.orgID)

        let result = await appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )
        let pending = try appState._debugSessionSnapshotUploadRetryWorkItemsForTests()
        let reloaded = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in },
            sessionSnapshotRowInsertOverride: { _ in },
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(reloaded, orgID: fixture.orgID)

        XCTAssertEqual(result?.outcome, .unavailable)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.status, .failed)
        XCTAssertEqual(pending.first?.attemptCount, 1)
        XCTAssertEqual(try reloaded._debugSessionSnapshotUploadRetryWorkItemsForTests(), pending)
    }

    func testSuccessfulRetryClearsQueuedSnapshotWork() async throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        let failing = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in
                throw AppState.SessionSnapshotUploadError.remoteUnavailable("test bucket unavailable")
            },
            sessionSnapshotRowInsertOverride: { _ in XCTFail("row insert should not run after storage failure") },
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(failing, orgID: fixture.orgID)
        _ = await failing.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater",
            attemptedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        var insertedRows: [AppState.SessionSnapshotUploadRow] = []
        let retrying = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in },
            sessionSnapshotRowInsertOverride: { row in insertedRows.append(row) },
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(retrying, orgID: fixture.orgID)

        let summary = await retrying._debugPerformSessionSnapshotUploadRetryForTests(
            now: Date(timeIntervalSinceReferenceDate: 1_100)
        )

        XCTAssertEqual(summary.attemptedCount, 1)
        XCTAssertEqual(summary.succeededCount, 1)
        XCTAssertEqual(insertedRows.count, 1)
        XCTAssertTrue(try retrying._debugSessionSnapshotUploadRetryWorkItemsForTests().isEmpty)
        XCTAssertEqual(retrying.sessionSnapshotCloudStatus(for: fixture.session)?.state, .uploaded)
        XCTAssertFalse(retrying.backendFeatureFlags.supabaseReadEnabled)
    }

    func testDuplicateSchedulingDuringBackoffDoesNotDuplicateRemoteAttempts() async throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        var storageAttemptCount = 0
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in
                storageAttemptCount += 1
                throw AppState.SessionSnapshotUploadError.remoteUnavailable("test bucket unavailable")
            },
            sessionSnapshotRowInsertOverride: { _ in XCTFail("row insert should not run after storage failure") },
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(appState, orgID: fixture.orgID)
        let now = Date(timeIntervalSinceReferenceDate: 2_000)

        _ = await appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater",
            attemptedAt: now
        )
        _ = await appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater",
            attemptedAt: now.addingTimeInterval(1)
        )

        let pending = try appState._debugSessionSnapshotUploadRetryWorkItemsForTests()
        XCTAssertEqual(storageAttemptCount, 1)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attemptCount, 1)
    }

    func testMissingArchiveReachesTerminalRetryFailure() async throws {
        let fixture = try makeFixture(autoUploadEnabled: false)
        let failing = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in
                throw AppState.SessionSnapshotUploadError.remoteUnavailable("test bucket unavailable")
            },
            sessionSnapshotRowInsertOverride: { _ in },
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(failing, orgID: fixture.orgID)
        _ = await failing.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater",
            attemptedAt: Date(timeIntervalSinceReferenceDate: 3_000)
        )
        let failedItem = try XCTUnwrap(try failing._debugSessionSnapshotUploadRetryWorkItemsForTests().first)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: failedItem.archivePath, isDirectory: true))
        let retrying = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in XCTFail("storage upload should not run with missing archive") },
            sessionSnapshotRowInsertOverride: { _ in XCTFail("row insert should not run with missing archive") },
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(retrying, orgID: fixture.orgID)

        let summary = await retrying._debugPerformSessionSnapshotUploadRetryForTests(
            now: Date(timeIntervalSinceReferenceDate: 3_100)
        )
        let terminal = try XCTUnwrap(try retrying._debugSessionSnapshotUploadRetryWorkItemsForTests().first)

        XCTAssertEqual(summary.attemptedCount, 1)
        XCTAssertEqual(summary.terminalFailedCount, 1)
        XCTAssertEqual(terminal.status, .terminalFailed)
        XCTAssertEqual(terminal.lastError, "archive_snapshot_missing_or_invalid")
    }

    func testRandomPropertyAndOrgAreSkipped() async throws {
        var attemptedStorageUpload = false
        let fixture = try makeFixture(
            autoUploadEnabled: true,
            orgAllowlist: [UUID()],
            propertyAllowlist: [UUID()],
            storageUploadOverride: { _ in attemptedStorageUpload = true }
        )

        let result = await fixture.appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedStorageUpload)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.autoUploadSkippedReason, "allowlist_no_match")
    }

    func testFailureIsNonBlockingAndDoesNotMutateLifecycleState() async throws {
        let fixture = try makeFixture(
            autoUploadEnabled: true,
            propertyAllowlist: []
        )
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: true, propertyAllowlist: [fixture.property.id]),
            environment: localEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in throw AppState.SessionSnapshotUploadError.remoteUnavailable("test bucket unavailable") },
            sessionSnapshotRowInsertOverride: { _ in XCTFail("row insert should not run after storage failure") },
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(appState, orgID: fixture.orgID)

        let result = await appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )
        let persisted = try XCTUnwrap(try fixture.store.fetchSessionsForCacheBuild(propertyID: fixture.property.id).first)

        XCTAssertEqual(result?.outcome, .unavailable)
        XCTAssertEqual(appState.localDiagnostics.sessionSnapshotUpload.lastAutoUploadOutcome, "unavailable")
        XCTAssertEqual(persisted.status, .completed)
        XCTAssertTrue(persisted.isSealed)
        XCTAssertEqual(persisted.endedAt, fixture.session.endedAt)
        XCTAssertFalse(appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertEqual(appState.localDiagnostics.sessionSnapshotUpload.lastReadbackStatus, "not_checked")
    }

    func testManualDiagnosticBehaviorUnchangedByAutoKillSwitch() async throws {
        var insertCount = 0
        let fixture = try makeFixture(
            autoUploadEnabled: true,
            propertyAllowlist: [],
            environmentExtras: ["SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_KILL_SWITCH": "true"],
            rowInsertOverride: { _ in insertCount += 1 }
        )
        fixture.appState.selectedPropertyID = fixture.property.id

        let result = await fixture.appState.uploadSessionSnapshotShadowWrite(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            kind: .manual,
            trigger: "manual_diagnostic"
        )

        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(insertCount, 1)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastKind, "manual")
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastTrigger, "manual_diagnostic")
    }

    func testProductionValidationRemainsManualOnlyForAutoUpload() async throws {
        var attemptedStorageUpload = false
        let fixture = try makeFixture(autoUploadEnabled: false)
        let productionEnvironment = [
            "SCOUTCAPTURE_SUPABASE_URL": "https://chlvazmtucoszicehtnm.supabase.co",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "production-validation-anon-key",
            "SCOUTCAPTURE_PRODUCTION_SNAPSHOT_VALIDATION_ALLOWED": "true",
            "SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_ENABLED": "true",
            "SCOUTCAPTURE_SESSION_SNAPSHOT_AUTO_UPLOAD_PROPERTY_ALLOWLIST": fixture.property.id.uuidString
        ]
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: makeDefaults(autoUploadEnabled: false),
            environment: productionEnvironment,
            sessionSnapshotStorageUploadOverride: { _ in attemptedStorageUpload = true },
            sessionSnapshotRowInsertOverride: { _ in },
            disableCloudBackupForTests: true
        )
        configureAuthenticatedContext(appState, orgID: fixture.orgID)

        let result = await appState.attemptAutomaticSessionSnapshotUploadForCompletedSealedCheckpoint(
            session: fixture.session,
            triggerSource: "sealCurrentSessionForExportLater"
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedStorageUpload)
        XCTAssertEqual(appState.localDiagnostics.sessionSnapshotUpload.autoUploadSkippedReason, "production_validation_manual_only")
    }
}
