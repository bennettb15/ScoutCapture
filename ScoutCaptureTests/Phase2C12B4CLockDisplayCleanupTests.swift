import XCTest
@testable import ScoutCapture

private actor AuditEventRecorder {
    private var eventTypes: [String] = []

    func append(_ eventType: String) {
        eventTypes.append(eventType)
    }

    func contains(_ eventType: String) -> Bool {
        eventTypes.contains(eventType)
    }
}

@MainActor
final class Phase2C12B4CLockDisplayCleanupTests: XCTestCase {
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let localStore: LocalStore
        let appState: AppState
        let orgID: UUID
        let property: Property
        let draftSession: Session
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "Phase2C12B4CLockDisplayCleanupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")
        defaults.set(true, forKey: "session_coordination_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C12B4C-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let orgID = UUID()
        let userID = UUID()
        _ = try localStore.createOrganization(Organization(id: orgID, name: "Test Org"))
        let property = try localStore.createProperty(
            Property(
                orgId: orgID,
                folderId: "lock-cleanup",
                name: "Lock Cleanup",
                address: "123 Cleanup Lane"
            )
        )

        let draftSession = try localStore.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .draft,
                endedAt: nil,
                exportedAt: nil,
                isSealed: false
            )
        )
        try localStore.ensureSessionMetadata(for: draftSession)
        var draftMetadata = try localStore.loadSessionMetadata(propertyID: property.id, sessionID: draftSession.id)
        draftMetadata.shots = [
            ShotMetadata(
                shotID: UUID(),
                propertyID: property.id,
                sessionID: draftSession.id,
                createdAt: Date(timeIntervalSinceReferenceDate: 101),
                capturedAtLocal: nil,
                updatedAt: Date(timeIntervalSinceReferenceDate: 101),
                building: "",
                elevation: "",
                detailType: "",
                angleIndex: 0,
                trade: nil,
                priority: nil,
                shotKey: "cleanup",
                isGuided: false,
                isFlagged: false,
                issueID: nil,
                issueStatus: nil,
                captureKind: nil,
                firstCaptureKind: nil,
                noteText: nil,
                noteCategory: nil,
                originalFilename: "draft.jpg",
                originalRelativePath: "Originals/draft.jpg",
                originalByteSize: 1024,
                stampedFilename: nil,
                stampedRelativePath: nil,
                captureMode: nil,
                lens: nil,
                exifOrientation: nil,
                orientation: nil,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil,
                imageWidth: nil,
                imageHeight: nil
            )
        ]
        try localStore.saveSessionMetadataAtomically(propertyID: property.id, sessionID: draftSession.id, metadata: draftMetadata)
        let draftOriginalURL = localStore
            .sessionFolderURL(propertyID: property.id, sessionID: draftSession.id)
            .appendingPathComponent("Originals/draft.jpg", isDirectory: false)
        try FileManager.default.createDirectory(
            at: draftOriginalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x01, 0x02, 0x03]).write(to: draftOriginalURL)

        let newerCompletedSession = try localStore.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 200),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 210),
                exportedAt: nil,
                isSealed: true
            )
        )
        try localStore.ensureSessionMetadata(for: newerCompletedSession)

        let appState = AppState(localStore: localStore, userDefaults: defaults, disableCloudBackupForTests: true)
        appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Test Org", role: "owner")
            ],
            activeOrganizationID: orgID,
            ready: true
        )
        appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: orgID,
            ready: true,
            clientConfigured: true,
            authenticated: true,
            authenticationReady: true,
            authenticatedUserID: userID
        )
        appState._debugRefreshPropertiesLocallyForTests()

        return Fixture(
            suiteName: suiteName,
            defaults: defaults,
            storageRoot: storageRoot,
            localStore: localStore,
            appState: appState,
            orgID: orgID,
            property: property,
            draftSession: draftSession
        )
    }

    private func tearDownFixture(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) {
            return parsed
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.timeZone = TimeZone(secondsFromGMT: 0)
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    private func seedPropertyStatus(
        fixture: Fixture,
        status: AppState.PropertyStatusValue,
        activeSessionID: UUID? = nil,
        draftSessionID: UUID? = nil,
        pendingExportSessionID: UUID? = nil,
        lastExportedSessionID: UUID? = nil,
        ownerUserID: UUID? = nil,
        ownerDeviceID: String? = nil,
        heartbeatAt: Date? = Date()
    ) {
        fixture.appState._debugReplacePropertyStatusCacheForTests([
            AppState.PropertyStatusRecord(
                propertyID: fixture.property.id,
                orgID: fixture.orgID,
                status: status,
                activeSessionID: activeSessionID,
                draftSessionID: draftSessionID,
                pendingExportSessionID: pendingExportSessionID,
                lastExportedSessionID: lastExportedSessionID,
                ownerUserID: ownerUserID,
                ownerDeviceID: ownerDeviceID,
                heartbeatAt: heartbeatAt,
                updatedAt: Date(),
                updatedBy: ownerUserID,
                statusReason: "test",
                revision: 1
            )
        ])
    }

    private func writeDeliveredArchivePackage(
        storageRoot: URL,
        propertyID: UUID,
        sessionID: UUID,
        createdByDeviceID: String?
    ) throws {
        let snapshotRoot = storageRoot
            .appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(propertyID.uuidString, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("20260527T120000Z-delivered-test", isDirectory: true)
        let payloadURL = snapshotRoot
            .appendingPathComponent("Payload", isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
        try FileManager.default.createDirectory(at: payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("archive-bytes".utf8).write(to: payloadURL)

        var manifest: [String: Any] = [
            "schemaVersion": 1,
            "createdAt": "2026-05-27T12:00:00Z",
            "trigger": "test",
            "propertyID": propertyID.uuidString,
            "sessionID": sessionID.uuidString,
            "sessionStatus": "completed",
            "isSealed": true,
            "firstDeliveredAt": "2026-05-27T12:01:00Z",
            "exportedAt": "2026-05-27T12:00:30Z",
            "fileCount": 1,
            "totalBytes": 13,
            "files": [
                [
                    "relativePath": "Payload/session.json",
                    "size": 13,
                    "sha256": "0c982986710a026635603031674053ca851fc0e3ea760094a34f59b84f7f6da6"
                ]
            ]
        ]
        if let createdByDeviceID {
            manifest["createdByDeviceID"] = createdByDeviceID
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: snapshotRoot.appendingPathComponent("manifest.json", isDirectory: false))
    }

    func testClearLockDisplayStateRemovesStaleDraftSessionCoordinationState() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.draftSession.id,
            lockedByUserID: UUID(),
            lockedByDeviceID: "other-device",
            lockedAt: Date()
        )

        XCTAssertTrue(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))

        fixture.appState._debugClearLockDisplayStateForTests(propertyIDs: [fixture.property.id])

        XCTAssertFalse(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))
    }

    func testRemoteCompletedSessionClearsStaleDraftAndLockUIState() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.draftSession.id,
            lockedByUserID: UUID(),
            lockedByDeviceID: "other-device",
            lockedAt: Date()
        )

        let completedAt = Date(timeIntervalSinceReferenceDate: 500)
        let result = fixture.appState._debugApplySyncDeltaSessionsForTests(
            records: [
                AppState.DebugRemoteSessionDeltaInput(
                    id: fixture.draftSession.id,
                    orgID: fixture.orgID,
                    propertyID: fixture.property.id,
                    title: "Lock Cleanup",
                    status: Session.Status.completed.rawValue,
                    startedAt: iso8601(fixture.draftSession.startedAt),
                    completedAt: iso8601(completedAt),
                    exportedAt: completedAt,
                    isSealed: true,
                    firstDeliveredAt: completedAt,
                    reExportExpiresAt: nil,
                    updatedAt: Date(),
                    deletedAt: nil
                )
            ],
            orgID: fixture.orgID
        )

        XCTAssertEqual(result.applied, 1)
        XCTAssertNil(fixture.appState.draftSession(for: fixture.property.id))
        XCTAssertFalse(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))
        let persisted = fixture.appState.sessions(for: fixture.property.id).first { $0.id == fixture.draftSession.id }
        XCTAssertEqual(persisted?.status, .completed)
        XCTAssertTrue(persisted?.isSealed == true)
        XCTAssertEqual(persisted?.exportedAt, completedAt)
    }

    func testRemoteFinalCoordinationClearsSecondDeviceDraftAndLockWithoutDelta() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.draftSession.id,
            lockedByUserID: UUID(),
            lockedByDeviceID: "device-a",
            lockedAt: Date()
        )
        XCTAssertNotNil(fixture.appState.draftSession(for: fixture.property.id))

        let exportedAt = Date(timeIntervalSinceReferenceDate: 650)
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.draftSession.id,
                orgID: fixture.orgID,
                propertyID: fixture.property.id,
                lockedByUserID: UUID(),
                lockedByDeviceID: "device-a",
                lockedAt: iso8601(exportedAt),
                coordinationTier1Snapshot: nil,
                updatedAt: exportedAt,
                status: Session.Status.completed.rawValue,
                completedAt: exportedAt,
                exportedAt: exportedAt,
                isSealed: true,
                firstDeliveredAt: exportedAt,
                reExportExpiresAt: nil
            )
        )

        let status = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id
        )

        if case .blocked = status {
            XCTFail("Finalized remote session must not keep another device locked out.")
        }
        XCTAssertNil(fixture.appState.draftSession(for: fixture.property.id))
        XCTAssertFalse(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))
        let persisted = try XCTUnwrap(fixture.appState.sessions(for: fixture.property.id).first { $0.id == fixture.draftSession.id })
        XCTAssertEqual(persisted.status, .completed)
        XCTAssertEqual(persisted.exportedAt, exportedAt)
        XCTAssertTrue(persisted.isSealed)
    }

    func testFinalSessionDiagnosticsSuppressDraftAndLockForSecondLogin() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let exportedAt = Date(timeIntervalSinceReferenceDate: 600)
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.draftSession.id,
                orgID: fixture.orgID,
                propertyID: fixture.property.id,
                lockedByUserID: UUID(),
                lockedByDeviceID: "other-device",
                lockedAt: iso8601(exportedAt),
                coordinationTier1Snapshot: nil,
                updatedAt: exportedAt,
                status: Session.Status.completed.rawValue,
                exportedAt: exportedAt,
                isSealed: true,
                firstDeliveredAt: exportedAt,
                reExportExpiresAt: nil
            )
        )
        _ = fixture.appState._debugApplySyncDeltaSessionsForTests(
            records: [
                AppState.DebugRemoteSessionDeltaInput(
                    id: fixture.draftSession.id,
                    orgID: fixture.orgID,
                    propertyID: fixture.property.id,
                    title: "Lock Cleanup",
                    status: Session.Status.completed.rawValue,
                    startedAt: iso8601(fixture.draftSession.startedAt),
                    completedAt: iso8601(exportedAt),
                    exportedAt: exportedAt,
                    isSealed: true,
                    firstDeliveredAt: exportedAt,
                    reExportExpiresAt: nil,
                    updatedAt: exportedAt,
                    deletedAt: nil
                )
            ],
            orgID: fixture.orgID
        )

        let diagnostics = fixture.appState.sessionUIStateDiagnostics(
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id
        )

        XCTAssertEqual(diagnostics?.computedShowsDraft, false)
        XCTAssertEqual(diagnostics?.computedShowsLock, false)
        XCTAssertEqual(diagnostics?.computedCanOpen, true)
        XCTAssertEqual(diagnostics?.reason, "final_session_suppresses_draft_and_lock")
    }

    func testMaterialDraftLockPersistsAfterHeartbeatTimeout() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.draftSession.id,
            lockedByUserID: UUID(),
            lockedByDeviceID: "other-device",
            lockedAt: Date()
        )

        XCTAssertTrue(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.draftSession.id,
            lockedByUserID: UUID(),
            lockedByDeviceID: "other-device",
            lockedAt: Date(timeIntervalSinceNow: -31 * 60)
        )

        XCTAssertTrue(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))
        let diagnostics = fixture.appState.sessionUIStateDiagnostics(
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id
        )
        XCTAssertEqual(diagnostics?.computedShowsLock, true)
        XCTAssertEqual(diagnostics?.computedCanOpen, false)
        XCTAssertEqual(diagnostics?.reason, "active_remote_lock")
    }

    func testDraftBadgeVisibleOnlyForOwningDeviceWhenMaterialDraftIsLocked() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let currentDeviceID = try XCTUnwrap(
            fixture.appState.sessionUIStateDiagnostics(
                propertyID: fixture.property.id,
                sessionID: fixture.draftSession.id
            )?.currentDeviceID
        )

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.draftSession.id,
            lockedByUserID: nil,
            lockedByDeviceID: currentDeviceID,
            lockedAt: Date()
        )
        seedPropertyStatus(
            fixture: fixture,
            status: .draft,
            activeSessionID: fixture.draftSession.id,
            draftSessionID: fixture.draftSession.id,
            ownerDeviceID: currentDeviceID
        )

        XCTAssertNotNil(fixture.appState.draftBadgeSession(for: fixture.property.id))
        XCTAssertFalse(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))
        var badgeModel = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertTrue(badgeModel.showDraft)
        XCTAssertFalse(badgeModel.showLock)
        XCTAssertEqual(badgeModel.draftReason, "property_status:draft:owner_match")

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.draftSession.id,
            lockedByUserID: nil,
            lockedByDeviceID: "other-device",
            lockedAt: Date()
        )
        seedPropertyStatus(
            fixture: fixture,
            status: .draft,
            activeSessionID: fixture.draftSession.id,
            draftSessionID: fixture.draftSession.id,
            ownerDeviceID: "other-device"
        )

        XCTAssertNil(fixture.appState.draftBadgeSession(for: fixture.property.id))
        XCTAssertTrue(fixture.appState.isSessionLockedByOther(sessionID: fixture.draftSession.id))

        let diagnostics = fixture.appState.sessionListContentDiagnostics(propertyID: fixture.property.id)
        XCTAssertEqual(diagnostics.badgeReason, "hidden_by_other_device_occupancy")
        XCTAssertEqual(diagnostics.draftOwnerDeviceID, "other-device")
        XCTAssertEqual(diagnostics.currentDeviceID, currentDeviceID)
        XCTAssertEqual(diagnostics.lockVisibilityReason, "active_occupancy_visible")
        badgeModel = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertFalse(badgeModel.showDraft)
        XCTAssertTrue(badgeModel.showLock)
        XCTAssertEqual(badgeModel.lockReason, "property_status:draft:owner_mismatch")
        XCTAssertEqual(badgeModel.draftReason, "property_status:draft:draft_hidden_owner_match=false")
    }

    func testMaterialDraftShowsLockedOnlyOnNonOwnerWhenOccupancyIsActive() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: fixture.draftSession.id,
            lockedByUserID: UUID(),
            lockedByDeviceID: "other-device",
            lockedAt: Date()
        )
        fixture.appState._debugSetPropertySessionOccupancyForTests(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            occupiedByUserID: UUID(),
            occupiedByDeviceID: "other-device",
            occupiedAt: Date()
        )
        seedPropertyStatus(
            fixture: fixture,
            status: .draft,
            activeSessionID: fixture.draftSession.id,
            draftSessionID: fixture.draftSession.id,
            ownerDeviceID: "other-device"
        )

        let badgeModel = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertTrue(badgeModel.showLock)
        XCTAssertFalse(badgeModel.showDraft)
        XCTAssertEqual(badgeModel.lockReason, "property_status:draft:owner_mismatch")
        XCTAssertEqual(badgeModel.draftReason, "property_status:draft:draft_hidden_owner_match=false")
        XCTAssertNil(fixture.appState.draftBadgeSession(for: fixture.property.id))
    }

    func testRefreshDoesNotHydrateVisibleLockBadgeFromMissingStatusOccupancy() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetRemotePropertySessionOccupancyOnlyForTests(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            occupiedByUserID: UUID(),
            occupiedByDeviceID: "other-device",
            occupiedAt: Date()
        )

        XCTAssertFalse(fixture.appState.propertyCardBadgeModel(for: fixture.property.id).showLock)

        await fixture.appState._debugRefreshVisibleLockBadgesFromEntrySourcesForTests(
            orgID: fixture.orgID,
            propertyIDs: [fixture.property.id],
            reason: "zero_photo_occupancy_test"
        )

        let badgeModel = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertFalse(badgeModel.showLock)
        XCTAssertFalse(badgeModel.showDraft)
        XCTAssertEqual(badgeModel.badgeSource, "property_status_missing")
        XCTAssertEqual(badgeModel.lockReason, "missing_property_status_row")
    }

    func testRefreshDoesNotHydrateVisibleLockBadgeFromMissingStatusMaterialDraftLock() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.draftSession.id,
                orgID: fixture.orgID,
                propertyID: fixture.property.id,
                lockedByUserID: UUID(),
                lockedByDeviceID: "other-device",
                lockedAt: iso8601(Date()),
                coordinationTier1Snapshot: nil,
                updatedAt: Date(),
                status: Session.Status.draft.rawValue,
                exportedAt: nil,
                isSealed: false,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil
            )
        )

        await fixture.appState._debugRefreshVisibleLockBadgesFromEntrySourcesForTests(
            orgID: fixture.orgID,
            propertyIDs: [fixture.property.id],
            reason: "material_draft_lock_test"
        )

        let badgeModel = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertFalse(badgeModel.showLock)
        XCTAssertFalse(badgeModel.showDraft)
        XCTAssertEqual(badgeModel.badgeSource, "property_status_missing")
        XCTAssertEqual(badgeModel.lockReason, "missing_property_status_row")
    }

    func testRefreshDoesNotHydrateVisibleLockBadgeFromMissingStatusExpiredMaterialDraftLock() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.draftSession.id,
                orgID: fixture.orgID,
                propertyID: fixture.property.id,
                lockedByUserID: UUID(),
                lockedByDeviceID: "other-device",
                lockedAt: iso8601(Date(timeIntervalSinceNow: -31 * 60)),
                coordinationTier1Snapshot: nil,
                updatedAt: Date(),
                status: Session.Status.draft.rawValue,
                exportedAt: nil,
                isSealed: false,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil
            )
        )

        await fixture.appState._debugRefreshVisibleLockBadgesFromEntrySourcesForTests(
            orgID: fixture.orgID,
            propertyIDs: [fixture.property.id],
            reason: "expired_material_draft_lock_test"
        )

        let badgeModel = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertFalse(badgeModel.showLock)
        XCTAssertFalse(badgeModel.showDraft)
        XCTAssertEqual(badgeModel.badgeSource, "property_status_missing")
        XCTAssertEqual(badgeModel.lockReason, "missing_property_status_row")
    }

    func testNewerExportEventClearsOlderLockOnRefresh() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let lockedAt = Date(timeIntervalSinceReferenceDate: 500)
        let exportedAt = Date(timeIntervalSinceReferenceDate: 550)
        fixture.appState.locallyLockedPropertyIDs.insert(fixture.property.id)
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.draftSession.id,
                orgID: fixture.orgID,
                propertyID: fixture.property.id,
                lockedByUserID: UUID(),
                lockedByDeviceID: "other-device",
                lockedAt: iso8601(lockedAt),
                coordinationTier1Snapshot: nil,
                updatedAt: lockedAt,
                status: Session.Status.draft.rawValue,
                exportedAt: nil,
                isSealed: false,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil
            )
        )
        fixture.appState._debugSetActivityFeedFetchOverrideForTests { orgID, propertyID, _ in
            return [
                fixture.appState._debugMakeActivityFeedItemForTests(
                    event: AppState.DebugActivityFeedEventInput(
                        id: UUID(),
                        orgID: orgID,
                        sessionID: fixture.draftSession.id,
                        actorUserID: nil,
                        eventType: "session.exported",
                        payload: [:],
                        createdAt: exportedAt
                    ),
                    propertyID: fixture.property.id,
                    propertyName: fixture.property.name,
                    sessionTitle: nil
                )
            ]
        }

        await fixture.appState._debugRefreshVisibleLockBadgesFromEntrySourcesForTests(
            orgID: fixture.orgID,
            propertyIDs: [fixture.property.id],
            reason: "newer_export_clears_lock_test"
        )

        let badgeModel = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertFalse(badgeModel.showLock)
        XCTAssertFalse(fixture.appState.locallyLockedPropertyIDs.contains(fixture.property.id))
    }

    func testEntryBlockingRespectsNewerReleaseEventOverOlderLock() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let lockedAt = Date(timeIntervalSinceReferenceDate: 600)
        let releasedAt = Date(timeIntervalSinceReferenceDate: 660)
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.draftSession.id,
                orgID: fixture.orgID,
                propertyID: fixture.property.id,
                lockedByUserID: UUID(),
                lockedByDeviceID: "other-device",
                lockedAt: iso8601(lockedAt),
                coordinationTier1Snapshot: nil,
                updatedAt: lockedAt,
                status: Session.Status.draft.rawValue,
                exportedAt: nil,
                isSealed: false,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil
            )
        )
        fixture.appState._debugSetActivityFeedFetchOverrideForTests { orgID, propertyID, _ in
            return [
                fixture.appState._debugMakeActivityFeedItemForTests(
                    event: AppState.DebugActivityFeedEventInput(
                        id: UUID(),
                        orgID: orgID,
                        sessionID: fixture.draftSession.id,
                        actorUserID: nil,
                        eventType: "session.released",
                        payload: [:],
                        createdAt: releasedAt
                    ),
                    propertyID: fixture.property.id,
                    propertyName: fixture.property.name,
                    sessionTitle: nil
                )
            ]
        }

        let status = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id
        )

        if case .blocked = status {
            XCTFail("Newer release event should override older lock and allow entry")
        }
    }

    func testOwnerRefreshShowsDraftForUnresolvedMaterialDraftLockAfterHeartbeatTimeout() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let currentDeviceID = fixture.appState._debugCurrentDeviceIdentifierForTests()
        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.draftSession.id,
                orgID: fixture.orgID,
                propertyID: fixture.property.id,
                lockedByUserID: nil,
                lockedByDeviceID: currentDeviceID,
                lockedAt: iso8601(Date(timeIntervalSinceNow: -31 * 60)),
                coordinationTier1Snapshot: nil,
                updatedAt: Date(),
                status: Session.Status.draft.rawValue,
                exportedAt: nil,
                isSealed: false,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil
            )
        )

        await fixture.appState._debugRefreshVisibleLockBadgesFromEntrySourcesForTests(
            orgID: fixture.orgID,
            propertyIDs: [fixture.property.id],
            reason: "owner_material_draft_lock_test"
        )

        let badgeModel = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertFalse(badgeModel.showLock)
        XCTAssertFalse(badgeModel.showDraft)
        XCTAssertEqual(badgeModel.badgeSource, "property_status_missing")
        XCTAssertEqual(badgeModel.draftReason, "missing_property_status_row")
        XCTAssertNotNil(fixture.appState.draftBadgeSession(for: fixture.property.id))
    }

    func testRefreshClearsReleasedOrStaleLockBadge() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.locallyLockedPropertyIDs.insert(fixture.property.id)
        fixture.appState._debugSetPropertySessionOccupancyForTests(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            occupiedByUserID: UUID(),
            occupiedByDeviceID: "other-device",
            occupiedAt: Date(timeIntervalSinceNow: -31 * 60)
        )

        await fixture.appState._debugRefreshVisibleLockBadgesFromEntrySourcesForTests(
            orgID: fixture.orgID,
            propertyIDs: [fixture.property.id],
            reason: "stale_lock_clear_test"
        )

        let badgeModel = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertFalse(badgeModel.showLock)
        XCTAssertFalse(fixture.appState.locallyLockedPropertyIDs.contains(fixture.property.id))
    }

    func testStoppedHeartbeatExpiresRemoteOccupancyLockBadge() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.locallyLockedPropertyIDs.insert(fixture.property.id)
        fixture.appState._debugSetRemotePropertySessionOccupancyOnlyForTests(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            occupiedByUserID: UUID(),
            occupiedByDeviceID: "force-closed-device",
            occupiedAt: Date(timeIntervalSinceNow: -31 * 60)
        )

        await fixture.appState._debugRefreshVisibleLockBadgesFromEntrySourcesForTests(
            orgID: fixture.orgID,
            propertyIDs: [fixture.property.id],
            reason: "stopped_heartbeat_test"
        )

        let badgeModel = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertFalse(badgeModel.showLock)
        XCTAssertFalse(fixture.appState.locallyLockedPropertyIDs.contains(fixture.property.id))
    }

    func testForegroundRecoveryRenewsValidActiveSessionOccupancy() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState.selectProperty(id: fixture.property.id)
        let activeSession = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let deviceID = fixture.appState._debugCurrentDeviceIdentifierForTests()
        let oldOccupiedAt = Date(timeIntervalSinceNow: -31 * 60)
        fixture.appState._debugSetRemotePropertySessionOccupancyOnlyForTests(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            occupiedByUserID: nil,
            occupiedByDeviceID: deviceID,
            occupiedAt: oldOccupiedAt
        )

        await fixture.appState._debugReconcileOccupancyForAppLifecycleForTests(reason: "foreground_recovery_test")

        let renewed = fixture.appState._debugReadRemotePropertySessionOccupancyForTests(propertyID: fixture.property.id)
        XCTAssertEqual(renewed.occupiedByDeviceID, deviceID)
        let renewedAt = try XCTUnwrap(parseISO8601(renewed.occupiedAt))
        XCTAssertGreaterThan(renewedAt, oldOccupiedAt)
        XCTAssertEqual(activeSession.propertyID, fixture.property.id)
    }

    func testForegroundRecoveryReleasesStaleNonActiveOwnedOccupancy() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let deviceID = fixture.appState._debugCurrentDeviceIdentifierForTests()
        fixture.appState._debugSetRemotePropertySessionOccupancyOnlyForTests(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            occupiedByUserID: nil,
            occupiedByDeviceID: deviceID,
            occupiedAt: Date(timeIntervalSinceNow: -31 * 60)
        )

        await fixture.appState._debugReconcileOccupancyForAppLifecycleForTests(reason: "foreground_recovery_test")

        let released = fixture.appState._debugReadRemotePropertySessionOccupancyForTests(propertyID: fixture.property.id)
        XCTAssertNil(released.occupiedByDeviceID)
        XCTAssertNil(released.occupiedAt)
    }

    func testMaterialDraftRemainsRecoverableAfterStaleOccupancyExpires() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetRemotePropertySessionOccupancyOnlyForTests(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            occupiedByUserID: UUID(),
            occupiedByDeviceID: "crashed-other-device",
            occupiedAt: Date(timeIntervalSinceNow: -31 * 60)
        )

        let status = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id
        )

        XCTAssertEqual(status, .allowed)
        let persistedSessions = try fixture.localStore.fetchSessions(propertyID: fixture.property.id)
        XCTAssertTrue(persistedSessions.contains { $0.id == fixture.draftSession.id })
        XCTAssertFalse(fixture.appState.locallyLockedPropertyIDs.contains(fixture.property.id))
    }

    func testStaleLocalDraftWithoutOwnershipDoesNotShowDraftBadge() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let badgeModel = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertFalse(badgeModel.showDraft)
        XCTAssertFalse(badgeModel.showLock)
        XCTAssertEqual(badgeModel.draftReason, "hidden_unverified_local_owner")
        XCTAssertNil(fixture.appState.draftBadgeSession(for: fixture.property.id))
    }

    func testDeliveredArchiveAvailabilityRequiresVerifiedCurrentDevicePackage() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        try writeDeliveredArchivePackage(
            storageRoot: fixture.storageRoot,
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id,
            createdByDeviceID: "device-a"
        )

        let ownerAvailability = try fixture.localStore.deliveredSessionArchivePackageAvailability(
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id,
            expectedDeviceID: "device-a"
        )
        XCTAssertTrue(ownerAvailability.available)
        XCTAssertTrue(ownerAvailability.pathExists)
        XCTAssertTrue(ownerAvailability.checksumVerified)
        XCTAssertEqual(ownerAvailability.originatingDeviceID, "device-a")

        let secondDeviceAvailability = try fixture.localStore.deliveredSessionArchivePackageAvailability(
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id,
            expectedDeviceID: "device-b"
        )
        XCTAssertFalse(secondDeviceAvailability.available)
        XCTAssertEqual(secondDeviceAvailability.reason, "archive_device_mismatch_or_missing")
    }

    func testDeliveredArchiveMetadataWithoutFileDoesNotEnableReExport() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        try writeDeliveredArchivePackage(
            storageRoot: fixture.storageRoot,
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id,
            createdByDeviceID: "device-a"
        )
        let payloadURL = fixture.storageRoot
            .appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(fixture.property.id.uuidString, isDirectory: true)
            .appendingPathComponent(fixture.draftSession.id.uuidString, isDirectory: true)
            .appendingPathComponent("20260527T120000Z-delivered-test", isDirectory: true)
            .appendingPathComponent("Payload", isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
        try FileManager.default.removeItem(at: payloadURL)

        let availability = try fixture.localStore.deliveredSessionArchivePackageAvailability(
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id,
            expectedDeviceID: "device-a"
        )

        XCTAssertFalse(availability.available)
        XCTAssertTrue(availability.pathExists)
        XCTAssertFalse(availability.checksumVerified)
        XCTAssertEqual(availability.reason, "delivered_archive_payload_missing_or_invalid")
    }

    func testTwoPhotoExportIncludesTwoVerifiedUniqueOriginalFiles() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let session = try fixture.localStore.upsertSession(
            Session(
                id: UUID(),
                propertyID: fixture.property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 850),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 860),
                exportedAt: nil,
                isSealed: true
            )
        )
        try fixture.localStore.ensureSessionMetadata(for: session)
        var metadata = try fixture.localStore.loadSessionMetadata(propertyID: fixture.property.id, sessionID: session.id)
        let firstShotID = UUID()
        let secondShotID = UUID()
        metadata.shots = [
            ShotMetadata(
                shotID: firstShotID,
                propertyID: fixture.property.id,
                sessionID: session.id,
                createdAt: Date(timeIntervalSinceReferenceDate: 851),
                updatedAt: Date(timeIntervalSinceReferenceDate: 851),
                building: "Main",
                elevation: "North",
                detailType: "Overview",
                angleIndex: 1,
                shotKey: "main|north|overview|1",
                isGuided: true,
                isFlagged: false,
                issueID: nil,
                issueStatus: nil,
                noteText: nil,
                noteCategory: nil,
                originalFilename: "capture.heic",
                originalRelativePath: "Originals/shot-one.heic",
                originalByteSize: 11,
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
            ),
            ShotMetadata(
                shotID: secondShotID,
                propertyID: fixture.property.id,
                sessionID: session.id,
                createdAt: Date(timeIntervalSinceReferenceDate: 852),
                updatedAt: Date(timeIntervalSinceReferenceDate: 852),
                building: "Main",
                elevation: "North",
                detailType: "Detail",
                angleIndex: 2,
                shotKey: "main|north|detail|2",
                isGuided: true,
                isFlagged: false,
                issueID: nil,
                issueStatus: nil,
                noteText: nil,
                noteCategory: nil,
                originalFilename: "capture.heic",
                originalRelativePath: "Originals/shot-two.heic",
                originalByteSize: 12,
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
        ]
        try fixture.localStore.saveSessionMetadataAtomically(propertyID: fixture.property.id, sessionID: session.id, metadata: metadata)
        let originalsRoot = fixture.localStore.originalsDirectoryURL(propertyID: fixture.property.id, sessionID: session.id)
        try FileManager.default.createDirectory(at: originalsRoot, withIntermediateDirectories: true)
        try Data("first-photo".utf8).write(to: originalsRoot.appendingPathComponent("shot-one.heic"))
        try Data("second-photo".utf8).write(to: originalsRoot.appendingPathComponent("shot-two.heic"))

        let artifacts = try fixture.localStore.validatedSessionExportArtifacts(for: session)

        XCTAssertEqual(artifacts.originalFiles.count, 2)
        XCTAssertEqual(Set(artifacts.originalFiles.map(\.filename)).count, 2)
        XCTAssertTrue(artifacts.originalFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.sourceURL.path) })
        XCTAssertEqual(artifacts.metadata.shots.count, 2)
        XCTAssertEqual(Set(artifacts.metadata.shots.map(\.originalRelativePath)).count, 2)
        XCTAssertTrue(artifacts.metadata.shots.allSatisfy { $0.originalRelativePath.hasPrefix("Originals/") })
    }

    func testZeroPhotoDraftDoesNotCreateBadgeOrGetReusedForEntry() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let property = try fixture.localStore.createProperty(
            Property(orgId: fixture.orgID, folderId: "zero-photo", name: "Zero Photo", address: "1 Empty Way")
        )
        let emptyDraft = try fixture.localStore.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 700),
                status: .draft,
                endedAt: nil,
                exportedAt: nil,
                isSealed: false
            )
        )
        try fixture.localStore.ensureSessionMetadata(for: emptyDraft)
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        XCTAssertNil(fixture.appState.draftSession(for: property.id))
        fixture.appState.selectProperty(id: property.id)
        let selected = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        XCTAssertNotEqual(selected.id, emptyDraft.id)
        XCTAssertNil(fixture.appState.draftSession(for: property.id))
        XCTAssertEqual(fixture.appState.sessionListContentDiagnostics(propertyID: property.id).badgeReason, "no_captured_draft")
    }

    func testZeroPhotoEntryClaimsOccupancyAndExitReleasesWithAudit() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let property = try fixture.localStore.createProperty(
            Property(orgId: fixture.orgID, folderId: "zero-photo-occupancy", name: "Zero Occupancy", address: "2 Empty Way")
        )
        fixture.appState._debugRefreshPropertiesLocallyForTests()
        fixture.appState.selectProperty(id: property.id)
        let session = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))

        let emittedEvents = AuditEventRecorder()
        fixture.appState._debugSetAuditEventEmitOverrideForTests { _, eventType, _, _, _ in
            await emittedEvents.append(eventType)
        }

        let entryStatus = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: property.id,
            sessionID: session.id
        )
        XCTAssertEqual(entryStatus, .allowed)
        XCTAssertNotNil(
            fixture.appState._debugReadRemotePropertySessionOccupancyForTests(propertyID: property.id).occupiedAt
        )
        let occupiedDiagnostics = fixture.appState.sessionListContentDiagnostics(propertyID: property.id)
        XCTAssertTrue(occupiedDiagnostics.occupancyActive)
        XCTAssertEqual(occupiedDiagnostics.materialContentCount, 0)
        XCTAssertNil(fixture.appState.draftSession(for: property.id))

        await fixture.appState.releaseCurrentSessionCoordinationLockIfOwned()

        let releasedOccupancy = fixture.appState._debugReadRemotePropertySessionOccupancyForTests(propertyID: property.id)
        XCTAssertNil(releasedOccupancy.occupiedByUserID)
        XCTAssertNil(releasedOccupancy.occupiedByDeviceID)
        XCTAssertNil(releasedOccupancy.occupiedAt)
        let emittedReleaseEvent = await emittedEvents.contains("session.released")
        XCTAssertTrue(emittedReleaseEvent)
        XCTAssertNil(fixture.appState.draftSession(for: property.id))
    }

    func testZeroPhotoCompletedShellDoesNotCreatePendingExportBadge() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let property = try fixture.localStore.createProperty(
            Property(orgId: fixture.orgID, folderId: "zero-photo-pending", name: "Zero Pending", address: "3 Empty Way")
        )
        let shell = try fixture.localStore.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 720),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 721),
                exportedAt: nil,
                isSealed: true
            )
        )
        try fixture.localStore.ensureSessionMetadata(for: shell)
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        XCTAssertNil(fixture.appState.latestPendingExportSession(for: property.id))
        XCTAssertEqual(fixture.appState.pendingExportCountAcrossProperties(), 0)
        XCTAssertEqual(fixture.appState.sessionListContentDiagnostics(propertyID: property.id).materialContentCount, 0)
    }

    func testStaleReleasedZeroPhotoOccupancyDoesNotBlockPropertyDelete() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let property = try fixture.localStore.createProperty(
            Property(orgId: fixture.orgID, folderId: "stale-zero-delete", name: "Stale Zero", address: "4 Empty Way")
        )
        fixture.appState._debugRefreshPropertiesLocallyForTests()
        fixture.appState._debugSetPropertySessionOccupancyForTests(
            propertyID: property.id,
            orgID: fixture.orgID,
            occupiedByUserID: UUID(),
            occupiedByDeviceID: "stale-device",
            occupiedAt: Date(timeIntervalSinceNow: -31 * 60)
        )

        var rpcCallCount = 0
        fixture.appState._debugSetPropertySoftDeleteOverridesForTests(
            rpc: { _ in rpcCallCount += 1 },
            refresh: { true }
        )

        let succeeded = await fixture.appState.remoteSoftDeleteProperty(id: property.id)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(rpcCallCount, 1)
    }

    func testActiveCapturedDraftLockBlocksDifferentSessionEntryForProperty() async throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        fixture.appState._debugSetSessionCoordinationFetchResultForTests(
            AppState.DebugSessionCoordinationRemoteInput(
                sessionID: fixture.draftSession.id,
                orgID: fixture.orgID,
                propertyID: fixture.property.id,
                lockedByUserID: UUID(),
                lockedByDeviceID: "device-a",
                lockedAt: iso8601(Date()),
                coordinationTier1Snapshot: nil,
                updatedAt: Date(),
                status: Session.Status.draft.rawValue,
                exportedAt: nil,
                isSealed: false,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil
            )
        )
        fixture.appState._debugSetPropertySessionOccupancyForTests(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            occupiedByUserID: UUID(),
            occupiedByDeviceID: "device-a",
            occupiedAt: Date()
        )

        let secondDeviceDraft = try fixture.localStore.upsertSession(
            Session(
                id: UUID(),
                propertyID: fixture.property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 800),
                status: .draft,
                endedAt: nil,
                exportedAt: nil,
                isSealed: false
            )
        )
        try fixture.localStore.ensureSessionMetadata(for: secondDeviceDraft)
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        let status = await fixture.appState.evaluateSessionEntryCoordination(
            propertyID: fixture.property.id,
            sessionID: secondDeviceDraft.id
        )
        if case .blocked = status {
            XCTAssertTrue(fixture.appState.locallyLockedPropertyIDs.contains(fixture.property.id))
            let badgeModel = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
            XCTAssertFalse(badgeModel.showLock)
            XCTAssertFalse(badgeModel.showDraft)
            XCTAssertEqual(badgeModel.badgeSource, "property_status_missing")
            XCTAssertEqual(badgeModel.lockReason, "missing_property_status_row")
            XCTAssertNil(fixture.appState.draftBadgeSession(for: fixture.property.id))
        } else {
            XCTFail("Expected active captured draft lock to block a different device/session entry.")
        }
    }

    func testRemoteCompletedShotMetadataHydratesCompletedSessionNotPreviousSession() throws {
        let fixture = try makeFixture()
        defer { tearDownFixture(fixture) }

        let completed = try fixture.localStore.upsertSession(
            Session(
                id: UUID(),
                propertyID: fixture.property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 900),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 920),
                exportedAt: Date(timeIntervalSinceReferenceDate: 925),
                isSealed: true
            )
        )
        try fixture.localStore.ensureSessionMetadata(for: completed)
        fixture.appState._debugRefreshPropertiesLocallyForTests()

        let shotID = UUID()
        let json = """
        [{
          "id": "\(shotID.uuidString)",
          "org_id": "\(fixture.orgID.uuidString)",
          "property_id": "\(fixture.property.id.uuidString)",
          "session_id": "\(completed.id.uuidString)",
          "created_at": "2001-01-01T00:16:00Z",
          "updated_at": "2001-01-01T00:16:01Z",
          "building": "Main",
          "elevation": "North",
          "detail_type": "Overview",
          "angle_index": 1,
          "shot_key": "main|north|overview|1",
          "is_guided": false,
          "is_flagged": false,
          "lifecycle_state": "active",
          "storage_bucket": "session-media",
          "storage_path": "org/property/session/\(shotID.uuidString).heic",
          "upload_state": "uploaded"
        }]
        """
        XCTAssertEqual(
            fixture.appState._debugApplyRemoteShotMetadataJSONForTests(
                json,
                propertyID: fixture.property.id,
                sessionID: completed.id
            ),
            1
        )

        let completedMetadata = try fixture.localStore.loadSessionMetadata(propertyID: fixture.property.id, sessionID: completed.id)
        XCTAssertEqual(completedMetadata.shots.map(\.shotID), [shotID])
        XCTAssertEqual(completedMetadata.shots.first?.sessionID, completed.id)
        XCTAssertEqual(completedMetadata.shots.first?.originalRelativePath, "Originals/\(shotID.uuidString).heic")

        let draftMetadata = try fixture.localStore.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.draftSession.id)
        XCTAssertFalse(draftMetadata.shots.contains { $0.shotID == shotID })

        let wrongSessionShotID = UUID()
        let wrongSessionJSON = """
        [{
          "id": "\(wrongSessionShotID.uuidString)",
          "org_id": "\(fixture.orgID.uuidString)",
          "property_id": "\(fixture.property.id.uuidString)",
          "session_id": "\(completed.id.uuidString)",
          "created_at": "2001-01-01T00:17:00Z",
          "updated_at": "2001-01-01T00:17:01Z",
          "building": "Main",
          "elevation": "North",
          "detail_type": "Overview",
          "angle_index": 2,
          "shot_key": "main|north|overview|2",
          "is_guided": true,
          "storage_bucket": "session-media",
          "storage_path": "org/property/session/\(wrongSessionShotID.uuidString).heic"
        }]
        """
        _ = fixture.appState._debugApplyRemoteShotMetadataJSONForTests(
            wrongSessionJSON,
            propertyID: fixture.property.id,
            sessionID: fixture.draftSession.id
        )
        let reloadedDraftMetadata = try fixture.localStore.loadSessionMetadata(propertyID: fixture.property.id, sessionID: fixture.draftSession.id)
        XCTAssertFalse(reloadedDraftMetadata.shots.contains { $0.shotID == wrongSessionShotID })
    }
}
