import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C27FZ4PropertyStatusDiagnosticsTests: XCTestCase {
    func testPropertyStatusRecordDecodesOperationalFields() throws {
        let propertyID = UUID()
        let orgID = UUID()
        let activeSessionID = UUID()
        let draftSessionID = UUID()
        let ownerUserID = UUID()
        let updatedBy = UUID()
        let json = """
        {
          "property_id": "\(propertyID.uuidString)",
          "org_id": "\(orgID.uuidString)",
          "status": "draft",
          "active_session_id": "\(activeSessionID.uuidString)",
          "draft_session_id": "\(draftSessionID.uuidString)",
          "pending_export_session_id": null,
          "last_exported_session_id": null,
          "owner_user_id": "\(ownerUserID.uuidString)",
          "owner_device_id": "device-a",
          "heartbeat_at": "2026-06-02T12:00:00Z",
          "updated_at": "2026-06-02T12:01:00Z",
          "updated_by": "\(updatedBy.uuidString)",
          "status_reason": "test:draft",
          "revision": 7
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(
            AppState.PropertyStatusRecord.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(record.propertyID, propertyID)
        XCTAssertEqual(record.orgID, orgID)
        XCTAssertEqual(record.status, .draft)
        XCTAssertEqual(record.activeSessionID, activeSessionID)
        XCTAssertEqual(record.draftSessionID, draftSessionID)
        XCTAssertEqual(record.ownerUserID, ownerUserID)
        XCTAssertEqual(record.ownerDeviceID, "device-a")
        XCTAssertEqual(record.updatedBy, updatedBy)
        XCTAssertEqual(record.statusReason, "test:draft")
        XCTAssertEqual(record.revision, 7)
        XCTAssertTrue(record.sessionIDDiagnosticSummary.contains("draft=\(draftSessionID.uuidString)"))
    }

    func testOwnerDraftPropertyStatusMatchesDerivedDraftBadge() {
        let propertyID = UUID()
        let userID = UUID()
        let sessionID = UUID()
        let record = AppState.PropertyStatusRecord(
            propertyID: propertyID,
            orgID: UUID(),
            status: .draft,
            activeSessionID: nil,
            draftSessionID: sessionID,
            pendingExportSessionID: nil,
            lastExportedSessionID: nil,
            ownerUserID: userID,
            ownerDeviceID: "device-a",
            heartbeatAt: Date(),
            updatedAt: Date(),
            updatedBy: userID,
            statusReason: "test:draft",
            revision: 1
        )
        let derived = AppState.PropertyStatusDerivedSummary(
            draftBadgeDecision: true,
            pendingExportDecision: false,
            lockedDecision: false,
            entryBlockingDecision: "allowed_by_existing_state",
            deleteEligibilityDecision: "blocked_by_draft_badge",
            compareAnswer: AppState.PropertyStatusCompareAnswer(
                visibleBadgeState: .draft,
                draftCountIncluded: true,
                pendingExportCountIncluded: false,
                entryBlocked: false,
                deleteEligible: false
            )
        )

        let comparison = AppState.makePropertyStatusDiagnosticComparison(
            propertyID: propertyID,
            record: record,
            derivedSummary: derived,
            currentUserID: userID,
            currentDeviceID: "device-a",
            refreshElapsedMs: 12
        )

        XCTAssertTrue(comparison.rowFound)
        XCTAssertEqual(comparison.status, .draft)
        XCTAssertTrue(comparison.statusMatch)
        XCTAssertEqual(comparison.statusMismatchReason, "matched")
        XCTAssertTrue(comparison.statusMismatchCategories.isEmpty)
    }

    func testNonOwnerDraftPropertyStatusExpectsLockedNotDraft() {
        let propertyID = UUID()
        let record = AppState.PropertyStatusRecord(
            propertyID: propertyID,
            orgID: UUID(),
            status: .draft,
            activeSessionID: nil,
            draftSessionID: UUID(),
            pendingExportSessionID: nil,
            lastExportedSessionID: nil,
            ownerUserID: UUID(),
            ownerDeviceID: "device-a",
            heartbeatAt: Date(),
            updatedAt: Date(),
            updatedBy: nil,
            statusReason: "test:draft",
            revision: 2
        )
        let derived = AppState.PropertyStatusDerivedSummary(
            draftBadgeDecision: true,
            pendingExportDecision: false,
            lockedDecision: false,
            entryBlockingDecision: "allowed_by_existing_state",
            deleteEligibilityDecision: "blocked_by_draft_badge",
            compareAnswer: AppState.PropertyStatusCompareAnswer(
                visibleBadgeState: .draft,
                draftCountIncluded: true,
                pendingExportCountIncluded: false,
                entryBlocked: false,
                deleteEligible: false
            )
        )

        let comparison = AppState.makePropertyStatusDiagnosticComparison(
            propertyID: propertyID,
            record: record,
            derivedSummary: derived,
            currentUserID: UUID(),
            currentDeviceID: "device-b",
            refreshElapsedMs: 3
        )

        XCTAssertFalse(comparison.statusMatch)
        XCTAssertTrue(comparison.statusMismatchReason.contains("draft_badge expected=false actual=true"))
        XCTAssertTrue(comparison.statusMismatchReason.contains("locked expected=true actual=false"))
        XCTAssertTrue(comparison.statusMismatchCategories.contains("badge_state"))
        XCTAssertTrue(comparison.statusMismatchCategories.contains("entry_block"))
    }

    func testMissingPropertyStatusRowIsReportedAsDiagnosticMismatchOnly() {
        let derived = AppState.PropertyStatusDerivedSummary(
            draftBadgeDecision: false,
            pendingExportDecision: false,
            lockedDecision: false,
            entryBlockingDecision: "allowed_by_existing_state",
            deleteEligibilityDecision: "eligible_by_existing_badge_state"
        )

        let comparison = AppState.makePropertyStatusDiagnosticComparison(
            propertyID: UUID(),
            record: nil,
            derivedSummary: derived,
            currentUserID: UUID(),
            currentDeviceID: "device-a",
            refreshElapsedMs: 1
        )

        XCTAssertFalse(comparison.rowFound)
        XCTAssertFalse(comparison.statusMatch)
        XCTAssertEqual(comparison.statusMismatchReason, "no_property_status_row")
        XCTAssertEqual(comparison.statusMismatchCategories, ["missing_property_status"])
    }

    func testExportedPropertyStatusMatchesDerivedExportedBadge() {
        let propertyID = UUID()
        let userID = UUID()
        let record = AppState.PropertyStatusRecord(
            propertyID: propertyID,
            orgID: UUID(),
            status: .exported,
            activeSessionID: nil,
            draftSessionID: nil,
            pendingExportSessionID: nil,
            lastExportedSessionID: UUID(),
            ownerUserID: nil,
            ownerDeviceID: nil,
            heartbeatAt: nil,
            updatedAt: Date(),
            updatedBy: userID,
            statusReason: "test:exported",
            revision: 3
        )
        let derived = AppState.PropertyStatusDerivedSummary(
            draftBadgeDecision: false,
            pendingExportDecision: false,
            lockedDecision: false,
            entryBlockingDecision: "allowed_by_existing_state",
            deleteEligibilityDecision: "eligible_by_existing_state",
            compareAnswer: AppState.PropertyStatusCompareAnswer(
                visibleBadgeState: .exported,
                draftCountIncluded: false,
                pendingExportCountIncluded: false,
                entryBlocked: false,
                deleteEligible: true
            )
        )

        let comparison = AppState.makePropertyStatusDiagnosticComparison(
            propertyID: propertyID,
            record: record,
            derivedSummary: derived,
            currentUserID: userID,
            currentDeviceID: "device-a",
            refreshElapsedMs: 2
        )

        XCTAssertTrue(comparison.statusMatch)
        XCTAssertEqual(comparison.statusMismatchReason, "matched")
    }

    func testExportedPropertyStatusReportsIdleDerivedMismatchWithoutCrash() {
        let propertyID = UUID()
        let record = AppState.PropertyStatusRecord(
            propertyID: propertyID,
            orgID: UUID(),
            status: .exported,
            activeSessionID: nil,
            draftSessionID: nil,
            pendingExportSessionID: nil,
            lastExportedSessionID: UUID(),
            ownerUserID: nil,
            ownerDeviceID: nil,
            heartbeatAt: nil,
            updatedAt: Date(),
            updatedBy: nil,
            statusReason: "test:exported",
            revision: 3
        )
        let derived = AppState.PropertyStatusDerivedSummary(
            draftBadgeDecision: false,
            pendingExportDecision: false,
            lockedDecision: false,
            entryBlockingDecision: "allowed_by_existing_state",
            deleteEligibilityDecision: "eligible_by_existing_state",
            compareAnswer: AppState.PropertyStatusCompareAnswer(
                visibleBadgeState: .idle,
                draftCountIncluded: false,
                pendingExportCountIncluded: false,
                entryBlocked: false,
                deleteEligible: true
            )
        )

        let comparison = AppState.makePropertyStatusDiagnosticComparison(
            propertyID: propertyID,
            record: record,
            derivedSummary: derived,
            currentUserID: UUID(),
            currentDeviceID: "device-a",
            refreshElapsedMs: 2
        )

        XCTAssertFalse(comparison.statusMatch)
        XCTAssertTrue(comparison.statusMismatchReason.contains("badge_state expected=exported actual=idle"))
        XCTAssertEqual(comparison.statusMismatchCategories, ["badge_state"])
    }

    func testPropertyStatusCompareSummaryCountsCategories() {
        let missing = AppState.makePropertyStatusDiagnosticComparison(
            propertyID: UUID(),
            record: nil,
            derivedSummary: AppState.PropertyStatusDerivedSummary(
                draftBadgeDecision: false,
                pendingExportDecision: false,
                lockedDecision: false,
                entryBlockingDecision: "allowed_by_existing_state",
                deleteEligibilityDecision: "eligible_by_existing_state"
            ),
            currentUserID: UUID(),
            currentDeviceID: "device-a",
            refreshElapsedMs: 1
        )
        let summary = AppState.makePropertyStatusCompareSummary(comparisons: [missing])

        XCTAssertEqual(summary.comparedPropertyCount, 1)
        XCTAssertEqual(summary.matchedCount, 0)
        XCTAssertEqual(summary.mismatchCount, 1)
        XCTAssertEqual(summary.missingPropertyStatusCount, 1)
        XCTAssertEqual(summary.mismatchCategories["missing_property_status"], 1)
    }

    func testPropertyStatusOwnerDraftDrivesBadgeAndDraftCount() throws {
        let fixture = try makeCutoverFixture()
        let deviceID = fixture.appState._debugCurrentDeviceIdentifierForTests()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: UUID(),
            ownerUserID: fixture.userID,
            ownerDeviceID: deviceID
        )

        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(badge.badgeSource, "property_status")
        XCTAssertTrue(badge.showDraft)
        XCTAssertFalse(badge.showLock)
        XCTAssertFalse(badge.showPendingExport)
        XCTAssertEqual(fixture.appState.draftPropertyCount(), 1)
        XCTAssertEqual(fixture.appState.pendingExportCountAcrossProperties(), 0)
        XCTAssertEqual(fixture.appState.draftCountSource(), "property_status_with_legacy_missing_rows")
    }

    func testPropertyStatusNonOwnerDraftDrivesLockedBadgeOnly() throws {
        let fixture = try makeCutoverFixture()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "other-device"
        )

        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(badge.badgeSource, "property_status")
        XCTAssertTrue(badge.showLock)
        XCTAssertFalse(badge.showDraft)
        XCTAssertFalse(badge.showPendingExport)
        XCTAssertEqual(fixture.appState.draftPropertyCount(), 0)
        XCTAssertEqual(fixture.appState.pendingExportCountAcrossProperties(), 0)
    }

    func testPropertyStatusPendingExportDrivesBadgeAndPendingCount() throws {
        let fixture = try makeCutoverFixture()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: UUID(),
            ownerUserID: fixture.userID,
            ownerDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests()
        )

        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(badge.badgeSource, "property_status")
        XCTAssertFalse(badge.showDraft)
        XCTAssertFalse(badge.showLock)
        XCTAssertTrue(badge.showPendingExport)
        XCTAssertEqual(fixture.appState.draftPropertyCount(), 0)
        XCTAssertEqual(fixture.appState.pendingExportCountAcrossProperties(), 1)
        XCTAssertEqual(fixture.appState.pendingExportCountSource(), "property_status_with_legacy_missing_rows")
    }

    func testMissingPropertyStatusRowFallsBackToLegacyDraftBadge() throws {
        let fixture = try makeCutoverFixture()
        let draft = try seedCapturedDraft(propertyID: fixture.property.id, localStore: fixture.localStore)
        fixture.appState._debugRefreshPropertiesLocallyForTests()
        fixture.appState._debugSetSessionCoordinationStateForTests(
            sessionID: draft.id,
            lockedByUserID: fixture.userID,
            lockedByDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests(),
            lockedAt: Date()
        )

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(badge.badgeSource, "legacy")
        XCTAssertTrue(badge.showDraft)
        XCTAssertFalse(badge.showLock)
        XCTAssertEqual(fixture.appState.draftPropertyCount(), 1)
        XCTAssertEqual(fixture.appState.draftCountSource(), "legacy")
    }

    func testPropertyStatusNonOwnerDraftBlocksEntryBeforeSessionCreation() throws {
        let fixture = try makeCutoverFixture()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "other-device"
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        fixture.appState.selectProperty(id: fixture.property.id)
        let session = fixture.appState.startSession()

        XCTAssertNil(session)
        XCTAssertNil(fixture.appState.currentSession)
        XCTAssertTrue(fixture.appState.sessions(for: fixture.property.id).isEmpty)
    }

    func testPropertyStatusOwnerDraftAllowsEntryAndReusesDraft() throws {
        let fixture = try makeCutoverFixture()
        let draft = try seedCapturedDraft(propertyID: fixture.property.id, localStore: fixture.localStore)
        fixture.appState._debugRefreshPropertiesLocallyForTests()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: draft.id,
            ownerUserID: fixture.userID,
            ownerDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests()
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        fixture.appState.selectProperty(id: fixture.property.id)
        let session = fixture.appState.startSession()

        XCTAssertEqual(session?.id, draft.id)
        XCTAssertEqual(fixture.appState.currentSession?.id, draft.id)
    }

    func testPropertyStatusNonOwnerOccupiedBlocksEntry() throws {
        let fixture = try makeCutoverFixture()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "other-device"
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        fixture.appState.selectProperty(id: fixture.property.id)
        let session = fixture.appState.startSession()

        XCTAssertNil(session)
        XCTAssertNil(fixture.appState.currentSession)
        XCTAssertTrue(fixture.appState.sessions(for: fixture.property.id).isEmpty)
    }

    func testPropertyStatusPendingExportBlocksEntryBeforeNewDraft() throws {
        let fixture = try makeCutoverFixture()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: UUID(),
            ownerUserID: fixture.userID,
            ownerDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests()
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        fixture.appState.selectProperty(id: fixture.property.id)
        let session = fixture.appState.startSession()

        XCTAssertNil(session)
        XCTAssertNil(fixture.appState.currentSession)
        XCTAssertTrue(fixture.appState.sessions(for: fixture.property.id).isEmpty)
    }

    func testPropertyStatusExportedAllowsEntry() throws {
        let fixture = try makeCutoverFixture()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .exported,
            lastExportedSessionID: UUID(),
            ownerUserID: nil,
            ownerDeviceID: nil
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        fixture.appState.selectProperty(id: fixture.property.id)
        let session = fixture.appState.startSession()

        XCTAssertNotNil(session)
        XCTAssertEqual(session?.propertyID, fixture.property.id)
        XCTAssertEqual(fixture.appState.currentSession?.id, session?.id)
    }

    func testMissingPropertyStatusEntryFallsBackToLegacyStartSession() throws {
        let fixture = try makeCutoverFixture()

        fixture.appState.selectProperty(id: fixture.property.id)
        let session = fixture.appState.startSession()

        XCTAssertNotNil(session)
        XCTAssertEqual(session?.propertyID, fixture.property.id)
        XCTAssertEqual(fixture.appState.currentSession?.id, session?.id)
    }

    func testLoadDraftSessionBlockedByNonOwnerPropertyStatus() throws {
        let fixture = try makeCutoverFixture()
        _ = try seedCapturedDraft(propertyID: fixture.property.id, localStore: fixture.localStore)
        fixture.appState._debugRefreshPropertiesLocallyForTests()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "other-device"
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let loaded = fixture.appState.loadDraftSession(for: fixture.property.id)

        XCTAssertNil(loaded)
        XCTAssertNil(fixture.appState.currentSession)
    }

    func testDraftPromotionLocalCacheUpdateShowsOwnerDraftBadgeImmediately() throws {
        let fixture = try makeCutoverFixture()
        let sessionID = UUID()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: sessionID,
            ownerUserID: fixture.userID,
            ownerDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests()
        )

        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterDraftPromotionForTests(
            record,
            propertyID: fixture.property.id,
            sessionID: sessionID,
            reason: "test_draft_promotion_cache_update"
        )

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(fixture.appState.propertyStatusRecord(for: fixture.property.id)?.status, .draft)
        XCTAssertTrue(badge.showDraft)
        XCTAssertFalse(badge.showLock)
        XCTAssertFalse(badge.showPendingExport)
        XCTAssertEqual(fixture.appState.draftPropertyCount(), 1)
    }

    func testDraftPromotionLocalCacheUpdateRejectsNonOwnerReturnedRow() throws {
        let fixture = try makeCutoverFixture()
        let sessionID = UUID()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: sessionID,
            ownerUserID: UUID(),
            ownerDeviceID: "other-device"
        )

        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterDraftPromotionForTests(
            record,
            propertyID: fixture.property.id,
            sessionID: sessionID,
            reason: "test_reject_non_owner_draft_cache_update"
        )

        XCTAssertNil(fixture.appState.propertyStatusRecord(for: fixture.property.id))
        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertFalse(badge.showDraft)
        XCTAssertFalse(badge.showLock)
        XCTAssertEqual(fixture.appState.draftPropertyCount(), 0)
    }

    func testExportedPropertyStatusCacheUpdateClearsPendingExportBadge() throws {
        let fixture = try makeCutoverFixture()
        let sessionID = UUID()
        let pendingRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: sessionID,
            ownerUserID: fixture.userID,
            ownerDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests()
        )
        let exportedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .exported,
            lastExportedSessionID: sessionID,
            ownerUserID: nil,
            ownerDeviceID: nil
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([pendingRecord])
        XCTAssertTrue(fixture.appState.propertyCardBadgeModel(for: fixture.property.id).showPendingExport)

        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterExportForTests(
            exportedRecord,
            propertyID: fixture.property.id,
            sessionID: sessionID,
            reason: "test_exported_cache_update"
        )

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(fixture.appState.propertyStatusRecord(for: fixture.property.id)?.status, .exported)
        XCTAssertFalse(badge.showPendingExport)
        XCTAssertFalse(badge.showDraft)
        XCTAssertFalse(badge.showLock)
        XCTAssertEqual(fixture.appState.pendingExportCountAcrossProperties(), 0)
    }

    func testExportedPropertyStatusCacheUpdateIgnoresNonExportedReturnedRow() throws {
        let fixture = try makeCutoverFixture()
        let sessionID = UUID()
        let pendingRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: sessionID,
            ownerUserID: fixture.userID,
            ownerDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests()
        )
        let nonExportedReturnedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: UUID(),
            ownerUserID: fixture.userID,
            ownerDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests()
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([pendingRecord])

        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterExportForTests(
            nonExportedReturnedRecord,
            propertyID: fixture.property.id,
            sessionID: sessionID,
            reason: "test_reject_non_exported_cache_update"
        )

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(fixture.appState.propertyStatusRecord(for: fixture.property.id)?.status, .pendingExport)
        XCTAssertTrue(badge.showPendingExport)
        XCTAssertEqual(fixture.appState.pendingExportCountAcrossProperties(), 1)
    }

    func testPropertyStatusEntryBlockUsesFriendlyOwnerDescriptionWhenAvailable() throws {
        let fixture = try makeCutoverFixture()
        let ownerID = UUID()
        fixture.appState._debugSetActiveOrganizationMembersForTests([
            OrganizationAccessMember(
                id: ownerID,
                email: "owner@example.com",
                fullName: "Morgan Owner",
                role: "member",
                accessScope: "organization"
            )
        ])
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: UUID(),
            ownerUserID: ownerID,
            ownerDeviceID: "owner-device-abcdef"
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let decision = fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)

        XCTAssertEqual(decision?.decision, "block")
        XCTAssertEqual(decision?.block?.ownerDescription, "Morgan Owner on Device owner-de")
    }

    private struct CutoverFixture {
        let localStore: LocalStore
        let appState: AppState
        let orgID: UUID
        let userID: UUID
        let property: Property
    }

    private func makeCutoverFixture() throws -> CutoverFixture {
        let suiteName = "Phase2C27FZ4PropertyStatusCutover-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "session_coordination_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C27FZ4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let orgID = UUID()
        let userID = UUID()
        _ = try localStore.createOrganization(Organization(id: orgID, name: "Status Cutover Org"))
        let property = try localStore.createProperty(
            Property(orgId: orgID, folderId: "status-cutover", name: "Status Cutover", address: "1 Status Way")
        )
        let appState = AppState(localStore: localStore, userDefaults: defaults, disableCloudBackupForTests: true)
        appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(id: orgID, name: "Status Cutover Org", role: "owner")
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
        return CutoverFixture(
            localStore: localStore,
            appState: appState,
            orgID: orgID,
            userID: userID,
            property: property
        )
    }

    private func makeStatusRecord(
        propertyID: UUID,
        orgID: UUID,
        status: AppState.PropertyStatusValue,
        activeSessionID: UUID? = nil,
        draftSessionID: UUID? = nil,
        pendingExportSessionID: UUID? = nil,
        lastExportedSessionID: UUID? = nil,
        ownerUserID: UUID? = nil,
        ownerDeviceID: String? = nil
    ) -> AppState.PropertyStatusRecord {
        AppState.PropertyStatusRecord(
            propertyID: propertyID,
            orgID: orgID,
            status: status,
            activeSessionID: activeSessionID,
            draftSessionID: draftSessionID,
            pendingExportSessionID: pendingExportSessionID,
            lastExportedSessionID: lastExportedSessionID,
            ownerUserID: ownerUserID,
            ownerDeviceID: ownerDeviceID,
            heartbeatAt: Date(),
            updatedAt: Date(),
            updatedBy: ownerUserID,
            statusReason: "test:\(status.rawValue)",
            revision: 1
        )
    }

    private func seedCapturedDraft(propertyID: UUID, localStore: LocalStore) throws -> Session {
        let session = try localStore.upsertSession(
            Session(
                id: UUID(),
                propertyID: propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .draft,
                endedAt: nil,
                exportedAt: nil,
                isSealed: false
            )
        )
        try localStore.ensureSessionMetadata(for: session)
        var metadata = try localStore.loadSessionMetadata(propertyID: propertyID, sessionID: session.id)
        metadata.shots = [
            ShotMetadata(
                shotID: UUID(),
                propertyID: propertyID,
                sessionID: session.id,
                createdAt: Date(timeIntervalSinceReferenceDate: 101),
                updatedAt: Date(timeIntervalSinceReferenceDate: 101),
                building: "",
                elevation: "",
                detailType: "",
                angleIndex: 0,
                shotKey: "status-cutover",
                isGuided: false,
                isFlagged: false,
                issueID: nil,
                issueStatus: nil,
                noteText: nil,
                noteCategory: nil,
                originalFilename: "draft.jpg",
                originalRelativePath: "Originals/draft.jpg",
                originalByteSize: 1,
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
        try localStore.saveSessionMetadataAtomically(propertyID: propertyID, sessionID: session.id, metadata: metadata)
        let originalURL = localStore
            .sessionFolderURL(propertyID: propertyID, sessionID: session.id)
            .appendingPathComponent("Originals/draft.jpg", isDirectory: false)
        try FileManager.default.createDirectory(
            at: originalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(to: originalURL)
        return session
    }
}
