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
        XCTAssertEqual(fixture.appState.draftCountSource(), "property_status")
    }

    func testPropertyStatusOwnerDraftSameUserDifferentDeviceStillOwns() throws {
        let fixture = try makeCutoverFixture()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: UUID(),
            ownerUserID: fixture.userID,
            ownerDeviceID: "old-device"
        )

        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(badge.badgeSource, "property_status")
        XCTAssertTrue(badge.showDraft)
        XCTAssertFalse(badge.showLock)
        XCTAssertEqual(fixture.appState.draftPropertyCount(), 1)

        let preflight = fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)
        XCTAssertEqual(preflight?.decision, "allow")
        XCTAssertEqual(preflight?.reason, "draft_owned_by_current_actor")
        XCTAssertNil(preflight?.block)
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
        XCTAssertEqual(fixture.appState.pendingExportCountSource(), "property_status")
    }

    func testLocalOriginPendingExportDoesNotLockOriginatingDevice() throws {
        let fixture = try makeCutoverFixture()
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: session.id,
            ownerUserID: fixture.userID,
            ownerDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests()
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        let entry = fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)

        XCTAssertTrue(badge.showPendingExport)
        XCTAssertFalse(badge.showLock)
        XCTAssertEqual(entry?.decision, "allow")
        XCTAssertEqual(entry?.reason, "pending_export_owned_by_current_actor")
        XCTAssertTrue(fixture.appState.isPendingDelivery(session))
        XCTAssertEqual(fixture.appState.latestPendingExportSession(for: fixture.property.id)?.id, session.id)
    }

    func testSamePendingExportLocksAnotherDeviceEvenForSameUser() throws {
        let fixture = try makeCutoverFixture()
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: session.id,
            ownerUserID: fixture.userID,
            ownerDeviceID: "device-a-origin"
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        let entry = fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)

        XCTAssertTrue(badge.showPendingExport)
        XCTAssertTrue(badge.showLock)
        XCTAssertEqual(entry?.decision, "block")
        XCTAssertEqual(entry?.reason, "pending_export_owned_by_other_actor")
        XCTAssertEqual(entry?.block?.blockContext, "pending_export")
        XCTAssertFalse(fixture.appState.isPendingDelivery(session))
        XCTAssertNil(fixture.appState.latestPendingExportSession(for: fixture.property.id))
    }

    func testRemotePendingExportLockDetailDisplaysOwnerEmail() async throws {
        let fixture = try makeCutoverFixture()
        await stabilizeAsyncFixtureAuthContext(fixture)
        let ownerID = UUID()
        let pendingSince = Date(timeIntervalSinceReferenceDate: 809_255_700)
        fixture.appState._debugSetActiveOrganizationMembersForTests([
            OrganizationAccessMember(
                id: ownerID,
                email: "owner@example.com",
                fullName: nil,
                role: "field",
                accessScope: "org"
            )
        ])
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: UUID(),
            ownerUserID: ownerID,
            ownerDeviceID: "device-a-origin",
            updatedAt: pendingSince
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let evaluation = await fixture.appState.evaluateFreshPropertyStatusEntryPreflight(
            propertyID: fixture.property.id,
            context: "test_pending_export_owner_email"
        )
        let block = try XCTUnwrap(evaluation.decision?.block)
        let message = AppState.sessionEntryBlockMessage(for: block) { _ in "Aug 19, 9:15 AM" }

        XCTAssertEqual(block.blockContext, "pending_export")
        XCTAssertEqual(block.ownerDescription, "owner@example.com")
        XCTAssertEqual(message, "Locked by: owner@example.com\nPending since: Aug 19, 9:15 AM")
    }

    func testRemotePendingExportLockDetailUsesUpdatedByOwnerEmailWhenOwnerFieldsAreCleared() async throws {
        let fixture = try makeCutoverFixture()
        await stabilizeAsyncFixtureAuthContext(fixture)
        let ownerID = UUID()
        let pendingSince = Date(timeIntervalSinceReferenceDate: 809_255_700)
        fixture.appState._debugSetActiveOrganizationMembersForTests([
            OrganizationAccessMember(
                id: ownerID,
                email: "device-a@example.com",
                fullName: nil,
                role: "field",
                accessScope: "org"
            )
        ])
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: UUID(),
            ownerUserID: nil,
            ownerDeviceID: nil,
            updatedAt: pendingSince,
            updatedBy: ownerID
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let evaluation = await fixture.appState.evaluateFreshPropertyStatusEntryPreflight(
            propertyID: fixture.property.id,
            context: "test_pending_export_updated_by_owner_email"
        )
        let block = try XCTUnwrap(evaluation.decision?.block)
        let message = AppState.sessionEntryBlockMessage(for: block) { _ in "Aug 19, 9:15 AM" }

        XCTAssertEqual(block.ownerDescription, "device-a@example.com")
        XCTAssertEqual(message, "Locked by: device-a@example.com\nPending since: Aug 19, 9:15 AM")
    }

    func testRemotePendingExportLockDetailFallsBackWhenOwnerEmailMissing() async throws {
        let fixture = try makeCutoverFixture()
        await stabilizeAsyncFixtureAuthContext(fixture)
        let ownerID = UUID()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: UUID(),
            ownerUserID: ownerID,
            ownerDeviceID: "device-a-origin"
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let evaluation = await fixture.appState.evaluateFreshPropertyStatusEntryPreflight(
            propertyID: fixture.property.id,
            context: "test_pending_export_owner_missing"
        )
        let block = try XCTUnwrap(evaluation.decision?.block)
        let message = AppState.sessionEntryBlockMessage(for: block) { _ in "Aug 19, 9:15 AM" }

        XCTAssertEqual(block.ownerDescription, "another user")
        XCTAssertFalse(message.contains(ownerID.uuidString))
        XCTAssertFalse(message.contains("device-a-origin"))
        XCTAssertEqual(message, "Locked by: another user\nPending since: Aug 19, 9:15 AM")
    }

    func testPendingExportWithClearedOwnerFieldsRemainsAccessibleOnOriginatingDevicePackage() throws {
        let fixture = try makeCutoverFixture()
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        let currentDeviceID = fixture.appState._debugCurrentDeviceIdentifierForTests()
        _ = try fixture.localStore.createSessionArchiveSnapshot(
            session: session,
            trigger: "test_pending_export_origin",
            deviceID: currentDeviceID
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: session.id,
            ownerUserID: nil,
            ownerDeviceID: nil,
            updatedBy: fixture.userID
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        let entry = fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)

        XCTAssertTrue(badge.showPendingExport)
        XCTAssertFalse(badge.showLock)
        XCTAssertEqual(entry?.decision, "allow")
        XCTAssertEqual(entry?.reason, "pending_export_owned_by_current_actor")
        XCTAssertTrue(fixture.appState.isPendingDelivery(session))
        XCTAssertEqual(fixture.appState.latestPendingExportSession(for: fixture.property.id)?.id, session.id)
    }

    func testPendingExportWithClearedOwnerFieldsStillLocksAnotherDeviceWithoutOriginPackage() throws {
        let fixture = try makeCutoverFixture()
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: session.id,
            ownerUserID: nil,
            ownerDeviceID: nil,
            updatedBy: fixture.userID
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        let entry = fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)

        XCTAssertTrue(badge.showPendingExport)
        XCTAssertTrue(badge.showLock)
        XCTAssertEqual(entry?.decision, "block")
        XCTAssertEqual(entry?.reason, "pending_export_owned_by_other_actor")
        XCTAssertFalse(fixture.appState.isPendingDelivery(session))
        XCTAssertNil(fixture.appState.latestPendingExportSession(for: fixture.property.id))
    }

    func testClaimRecoveryLoadsExistingPendingExportInsteadOfCreatingCaptureSession() throws {
        let fixture = try makeCutoverFixture()
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        let currentDeviceID = fixture.appState._debugCurrentDeviceIdentifierForTests()
        _ = try fixture.localStore.createSessionArchiveSnapshot(
            session: session,
            trigger: "test_claim_pending_export",
            deviceID: currentDeviceID
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: session.id,
            ownerUserID: nil,
            ownerDeviceID: nil,
            updatedBy: fixture.userID
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let recovery = fixture.appState.recoverLocalPendingExportForPropertyOpen(propertyID: fixture.property.id)

        XCTAssertEqual(recovery?.session.id, session.id)
        XCTAssertEqual(fixture.appState.currentSession?.id, session.id)
        XCTAssertEqual(fixture.appState.currentSession?.status, .completed)
        XCTAssertTrue(fixture.appState.currentSession?.isSealed == true)
        XCTAssertNil(fixture.appState.currentSession?.firstDeliveredAt)
    }

    func testClaimRecoveryDoesNotUnlockRemotePendingExportWithoutOriginPackage() throws {
        let fixture = try makeCutoverFixture()
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: session.id,
            ownerUserID: nil,
            ownerDeviceID: nil,
            updatedBy: fixture.userID
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        XCTAssertNil(fixture.appState.recoverLocalPendingExportForPropertyOpen(propertyID: fixture.property.id))
        XCTAssertNil(fixture.appState.currentSession)
    }

    func testFreshOccupiedPropertyStatusShowsLockedBadgeForNonOwner() throws {
        let fixture = try makeCutoverFixture()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "other-device",
            heartbeatAt: Date()
        )

        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(badge.badgeSource, "property_status")
        XCTAssertTrue(badge.showLock)
        XCTAssertFalse(badge.showDraft)
        XCTAssertFalse(badge.showPendingExport)
    }

    func testStaleOccupiedPropertyStatusDoesNotShowLockedBadge() throws {
        let fixture = try makeCutoverFixture()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "other-device",
            heartbeatAt: Date().addingTimeInterval(-4 * 60)
        )

        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(badge.badgeSource, "property_status")
        XCTAssertFalse(badge.showLock)
        XCTAssertFalse(badge.showDraft)
        XCTAssertFalse(badge.showPendingExport)
    }

    func testOldDraftPropertyStatusStillShowsLockedBadgeForNonOwner() throws {
        let fixture = try makeCutoverFixture()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "other-device",
            heartbeatAt: Date().addingTimeInterval(-4 * 60)
        )

        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(badge.badgeSource, "property_status")
        XCTAssertTrue(badge.showLock)
        XCTAssertFalse(badge.showDraft)
        XCTAssertFalse(badge.showPendingExport)
    }

    func testOldPendingExportPropertyStatusStillShowsPendingExportBadge() throws {
        let fixture = try makeCutoverFixture()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "other-device",
            heartbeatAt: Date().addingTimeInterval(-4 * 60)
        )

        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(badge.badgeSource, "property_status")
        XCTAssertTrue(badge.showLock)
        XCTAssertFalse(badge.showDraft)
        XCTAssertTrue(badge.showPendingExport)
    }

    func testMissingPropertyStatusRowDoesNotReconstructLegacyDraftBadge() throws {
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
        XCTAssertEqual(badge.badgeSource, "property_status_missing")
        XCTAssertFalse(badge.showDraft)
        XCTAssertFalse(badge.showLock)
        XCTAssertFalse(badge.showPendingExport)
        XCTAssertEqual(badge.draftReason, "missing_property_status_row")
        XCTAssertEqual(badge.lockReason, "missing_property_status_row")
        XCTAssertEqual(fixture.appState.draftPropertyCount(), 0)
        XCTAssertEqual(fixture.appState.draftCountSource(), "property_status_missing_rows")
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

    func testCachedExportedFreshRemoteOccupiedByOtherBlocksEntry() async throws {
        let fixture = try makeCutoverFixture()
        let cachedExported = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .exported,
            lastExportedSessionID: UUID(),
            ownerUserID: nil,
            ownerDeviceID: nil
        )
        let freshOccupied = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "device-b"
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([cachedExported])
        fixture.appState._debugSetPropertyStatusFetchOverrideForTests { _, _ in
            [freshOccupied]
        }

        let evaluation = await fixture.appState._debugEvaluateFreshPropertyStatusEntryPreflightForTests(
            propertyID: fixture.property.id,
            context: "test_cached_exported_fresh_occupied"
        )

        XCTAssertEqual(evaluation.source, "property_status_fresh")
        XCTAssertEqual(evaluation.decision?.decision, "block")
        XCTAssertEqual(evaluation.decision?.reason, "occupied_owned_by_other_actor")
        XCTAssertFalse(evaluation.skipCachedPropertyStatusPreflight)
        XCTAssertEqual(fixture.appState.propertyStatusRecord(for: fixture.property.id)?.status, .occupied)

        fixture.appState.selectProperty(id: fixture.property.id)
        let session = fixture.appState.startSession()
        XCTAssertNil(session)
        XCTAssertNil(fixture.appState.currentSession)
    }

    func testCachedIdleFreshRemoteOccupiedByOtherBlocksEntry() async throws {
        let fixture = try makeCutoverFixture()
        let cachedIdle = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .idle
        )
        let freshOccupied = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "device-b"
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([cachedIdle])
        fixture.appState._debugSetPropertyStatusFetchOverrideForTests { _, _ in
            [freshOccupied]
        }

        let evaluation = await fixture.appState._debugEvaluateFreshPropertyStatusEntryPreflightForTests(
            propertyID: fixture.property.id,
            context: "test_cached_idle_fresh_occupied"
        )

        XCTAssertEqual(evaluation.source, "property_status_fresh")
        XCTAssertEqual(evaluation.decision?.decision, "block")
        XCTAssertEqual(evaluation.decision?.reason, "occupied_owned_by_other_actor")
        XCTAssertEqual(fixture.appState.propertyStatusRecord(for: fixture.property.id)?.status, .occupied)

        fixture.appState.selectProperty(id: fixture.property.id)
        XCTAssertNil(fixture.appState.startSession())
    }

    func testStaleOccupiedPropertyStatusAllowsRpcClaimPath() async throws {
        let fixture = try makeCutoverFixture()
        let staleOccupied = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "device-b",
            heartbeatAt: Date().addingTimeInterval(-45 * 60)
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([staleOccupied])
        fixture.appState._debugSetPropertyStatusFetchOverrideForTests { _, _ in
            [staleOccupied]
        }

        let evaluation = await fixture.appState._debugEvaluateFreshPropertyStatusEntryPreflightForTests(
            propertyID: fixture.property.id,
            context: "test_stale_occupied_claimable"
        )

        XCTAssertEqual(evaluation.source, "property_status_fresh")
        XCTAssertEqual(evaluation.decision?.decision, "allow")
        XCTAssertEqual(evaluation.decision?.reason, "occupied_stale_claimable_via_rpc")
        XCTAssertNil(evaluation.decision?.block)
    }

    func testDraftPropertyStatusDoesNotAutoExpireFromOldHeartbeat() async throws {
        let fixture = try makeCutoverFixture()
        let staleDraft = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            activeSessionID: UUID(),
            draftSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "device-b",
            heartbeatAt: Date().addingTimeInterval(-45 * 60)
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([staleDraft])

        let evaluation = await fixture.appState._debugEvaluateFreshPropertyStatusEntryPreflightForTests(
            propertyID: fixture.property.id,
            context: "test_stale_draft_still_blocks"
        )

        XCTAssertEqual(evaluation.source, "property_status_cached")
        XCTAssertEqual(evaluation.decision?.decision, "block")
        XCTAssertEqual(evaluation.decision?.reason, "draft_owned_by_other_actor")
        XCTAssertEqual(evaluation.decision?.block?.blockContext, "draft")
    }

    func testPendingExportPropertyStatusDoesNotAutoExpireFromOldHeartbeat() async throws {
        let fixture = try makeCutoverFixture()
        let stalePendingExport = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: UUID(),
            heartbeatAt: Date().addingTimeInterval(-45 * 60)
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([stalePendingExport])

        let evaluation = await fixture.appState._debugEvaluateFreshPropertyStatusEntryPreflightForTests(
            propertyID: fixture.property.id,
            context: "test_stale_pending_export_still_blocks"
        )

        XCTAssertEqual(evaluation.source, "property_status_cached")
        XCTAssertEqual(evaluation.decision?.decision, "block")
        XCTAssertEqual(evaluation.decision?.reason, "pending_export_owned_by_other_actor")
        XCTAssertEqual(evaluation.decision?.block?.blockContext, "pending_export")
    }

    func testCachedOccupiedFreshRemoteIdleAllowsEntryAfterZeroPhotoRelease() async throws {
        let fixture = try makeCutoverFixture()
        let cachedOccupied = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "device-b"
        )
        let freshIdle = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .idle
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([cachedOccupied])
        fixture.appState._debugSetPropertyStatusFetchOverrideForTests { _, _ in
            [freshIdle]
        }

        let evaluation = await fixture.appState._debugEvaluateFreshPropertyStatusEntryPreflightForTests(
            propertyID: fixture.property.id,
            context: "test_cached_occupied_fresh_idle"
        )

        XCTAssertEqual(evaluation.source, "property_status_fresh")
        XCTAssertEqual(evaluation.decision?.decision, "allow")
        XCTAssertEqual(evaluation.decision?.reason, "status_idle")
        XCTAssertEqual(fixture.appState.propertyStatusRecord(for: fixture.property.id)?.status, .idle)

        fixture.appState.selectProperty(id: fixture.property.id)
        let session = fixture.appState.startSession()
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.propertyID, fixture.property.id)
    }

    func testRemotePropertyStatusReadFailureBlocksCanonicalEntryPath() async throws {
        let fixture = try makeCutoverFixture()
        let cachedExported = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .exported,
            lastExportedSessionID: UUID(),
            ownerUserID: nil,
            ownerDeviceID: nil
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([cachedExported])
        fixture.appState._debugSetPropertyStatusFetchOverrideForTests { _, _ in
            throw NSError(
                domain: "PropertyStatusFreshReadTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "forced fresh read failure"]
            )
        }

        let evaluation = await fixture.appState._debugEvaluateFreshPropertyStatusEntryPreflightForTests(
            propertyID: fixture.property.id,
            context: "test_fresh_read_failure"
        )

        XCTAssertEqual(evaluation.decision?.decision, "block")
        XCTAssertEqual(evaluation.decision?.block?.blockContext, "missing_property_status")
        XCTAssertFalse(evaluation.skipCachedPropertyStatusPreflight)
        XCTAssertEqual(evaluation.source, "property_status_unverified")
        XCTAssertEqual(evaluation.reason, "fresh_read_failed")

        fixture.appState.selectProperty(id: fixture.property.id)
        let session = fixture.appState.startSession(
            skipPropertyStatusPreflight: evaluation.skipCachedPropertyStatusPreflight
        )
        XCTAssertNil(session)
        XCTAssertNil(fixture.appState.currentSession)
    }

    func testMissingPropertyStatusFreshPreflightBlocksUntilCanonicalRowExists() async throws {
        let fixture = try makeCutoverFixture()

        let evaluation = await fixture.appState._debugEvaluateFreshPropertyStatusEntryPreflightForTests(
            propertyID: fixture.property.id,
            context: "test_missing_row"
        )

        XCTAssertEqual(evaluation.decision?.decision, "block")
        XCTAssertEqual(evaluation.decision?.block?.blockContext, "missing_property_status")
        XCTAssertFalse(evaluation.skipCachedPropertyStatusPreflight)
        XCTAssertEqual(evaluation.source, "property_status_missing")
        XCTAssertEqual(evaluation.reason, "missing_property_status_row")

        fixture.appState.selectProperty(id: fixture.property.id)
        let session = fixture.appState.startSession()
        XCTAssertNil(session)
        XCTAssertNil(fixture.appState.currentSession)
    }

    func testMissingPropertyStatusEntryBlocksLegacyStartSession() throws {
        let fixture = try makeCutoverFixture()

        fixture.appState.selectProperty(id: fixture.property.id)
        let session = fixture.appState.startSession()

        XCTAssertNil(session)
        XCTAssertNil(fixture.appState.currentSession)
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

    func testDraftPromotionLocalCacheUpdateAcceptsSameUserNullDeviceDraft() throws {
        let fixture = try makeCutoverFixture()
        let sessionID = UUID()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: sessionID,
            ownerUserID: fixture.userID,
            ownerDeviceID: nil
        )

        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterDraftPromotionForTests(
            record,
            propertyID: fixture.property.id,
            sessionID: sessionID,
            reason: "test_same_user_null_device_draft_cache_update"
        )

        let cached = fixture.appState.propertyStatusRecord(for: fixture.property.id)
        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(cached?.status, .draft)
        XCTAssertEqual(cached?.draftSessionID, sessionID)
        XCTAssertEqual(cached?.ownerUserID, fixture.userID)
        XCTAssertNil(cached?.ownerDeviceID)
        XCTAssertTrue(badge.showDraft)
        XCTAssertFalse(badge.showLock)
        XCTAssertEqual(fixture.appState.draftPropertyCount(), 1)
    }

    func testDraftPromotionLocalCacheUpdateAcceptsSameUserDifferentDeviceDraft() throws {
        let fixture = try makeCutoverFixture()
        let sessionID = UUID()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            draftSessionID: sessionID,
            ownerUserID: fixture.userID,
            ownerDeviceID: "old-device"
        )

        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterDraftPromotionForTests(
            record,
            propertyID: fixture.property.id,
            sessionID: sessionID,
            reason: "test_same_user_different_device_draft_cache_update"
        )

        let cached = fixture.appState.propertyStatusRecord(for: fixture.property.id)
        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(cached?.status, .draft)
        XCTAssertEqual(cached?.draftSessionID, sessionID)
        XCTAssertEqual(cached?.ownerUserID, fixture.userID)
        XCTAssertEqual(cached?.ownerDeviceID, "old-device")
        XCTAssertTrue(badge.showDraft)
        XCTAssertFalse(badge.showLock)
        XCTAssertEqual(fixture.appState.draftPropertyCount(), 1)
    }

    func testClaimReturnedOccupiedUpdatesLocalPropertyStatusCache() throws {
        let fixture = try makeCutoverFixture()
        fixture.appState.selectProperty(id: fixture.property.id)
        let session = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: session.id,
            ownerUserID: fixture.userID,
            ownerDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests()
        )

        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterClaimForTests(
            record,
            propertyID: fixture.property.id,
            sessionID: session.id,
            reason: "test_claim_cache_update"
        )

        let cached = fixture.appState.propertyStatusRecord(for: fixture.property.id)
        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(cached?.status, .occupied)
        XCTAssertEqual(cached?.activeSessionID, session.id)
        XCTAssertEqual(cached?.ownerUserID, fixture.userID)
        XCTAssertFalse(badge.showLock)
        XCTAssertFalse(badge.showDraft)
        XCTAssertFalse(badge.showPendingExport)
    }

    func testReleaseReturnedDraftWithSameUserNullDevicePreservesLocalDraftCache() throws {
        let fixture = try makeCutoverFixture()
        fixture.appState.selectProperty(id: fixture.property.id)
        let session = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let occupiedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: session.id,
            ownerUserID: fixture.userID,
            ownerDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests()
        )
        let draftRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .draft,
            activeSessionID: session.id,
            draftSessionID: session.id,
            ownerUserID: fixture.userID,
            ownerDeviceID: nil
        )
        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterClaimForTests(
            occupiedRecord,
            propertyID: fixture.property.id,
            sessionID: session.id,
            reason: "test_claim_before_draft_preserving_release"
        )

        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterReleaseForTests(
            draftRecord,
            propertyID: fixture.property.id,
            reason: "test_release_returned_draft"
        )

        let cached = fixture.appState.propertyStatusRecord(for: fixture.property.id)
        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(cached?.status, .draft)
        XCTAssertEqual(cached?.draftSessionID, session.id)
        XCTAssertEqual(cached?.ownerUserID, fixture.userID)
        XCTAssertNil(cached?.ownerDeviceID)
        XCTAssertTrue(badge.showDraft)
        XCTAssertFalse(badge.showLock)
        XCTAssertEqual(fixture.appState.draftPropertyCount(), 1)
    }

    func testZeroPhotoReleaseUpdatesLocalPropertyStatusCacheToIdle() throws {
        let fixture = try makeCutoverFixture()
        fixture.appState.selectProperty(id: fixture.property.id)
        let session = try XCTUnwrap(fixture.appState.startSession(skipPropertyStatusPreflight: true))
        let occupiedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: session.id,
            ownerUserID: fixture.userID,
            ownerDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests()
        )
        let idleRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .idle
        )
        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterClaimForTests(
            occupiedRecord,
            propertyID: fixture.property.id,
            sessionID: session.id,
            reason: "test_claim_before_release"
        )

        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterReleaseForTests(
            idleRecord,
            propertyID: fixture.property.id,
            reason: "test_zero_photo_release"
        )

        let cached = fixture.appState.propertyStatusRecord(for: fixture.property.id)
        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertEqual(cached?.status, .idle)
        XCTAssertNil(cached?.activeSessionID)
        XCTAssertFalse(badge.showLock)
        XCTAssertFalse(badge.showDraft)
        XCTAssertFalse(badge.showPendingExport)
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

    func testRemoteDeliveredPropertyStatusClearsPendingExportPresentationAndEntryBlock() throws {
        let fixture = try makeCutoverFixture()
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let pendingRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: session.id,
            ownerUserID: fixture.userID,
            ownerDeviceID: fixture.appState._debugCurrentDeviceIdentifierForTests()
        )
        let exportedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .exported,
            lastExportedSessionID: session.id
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([pendingRecord])
        XCTAssertTrue(fixture.appState.propertyCardBadgeModel(for: fixture.property.id).showPendingExport)
        XCTAssertTrue(fixture.appState.isPendingDelivery(session))

        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterExportForTests(
            exportedRecord,
            propertyID: fixture.property.id,
            sessionID: session.id,
            reason: "test_remote_delivered_state"
        )

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        let entry = fixture.appState.evaluatePropertyStatusEntryPreflight(
            propertyID: fixture.property.id,
            context: "test_remote_delivered_state"
        )
        let refreshed = try XCTUnwrap(fixture.appState.sessions(for: fixture.property.id).first { $0.id == session.id })
        XCTAssertFalse(badge.showPendingExport)
        XCTAssertFalse(badge.showLock)
        XCTAssertEqual(entry?.decision, "allow")
        XCTAssertEqual(entry?.reason, "status_exported")
        XCTAssertFalse(fixture.appState.isPendingDelivery(refreshed))
        XCTAssertNotNil(refreshed.exportedAt)
        XCTAssertNotNil(refreshed.firstDeliveredAt)
    }

    func testDeliveryExportClearsRemoteDevicePendingExportLock() throws {
        let fixture = try makeCutoverFixture()
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let pendingRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .pendingExport,
            pendingExportSessionID: session.id,
            ownerUserID: fixture.userID,
            ownerDeviceID: "device-a-origin"
        )
        let exportedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .exported,
            lastExportedSessionID: session.id
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([pendingRecord])
        XCTAssertTrue(fixture.appState.propertyCardBadgeModel(for: fixture.property.id).showLock)
        XCTAssertEqual(
            fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)?.block?.blockContext,
            "pending_export"
        )

        fixture.appState._debugUpdateLocalPropertyStatusCacheAfterExportForTests(
            exportedRecord,
            propertyID: fixture.property.id,
            sessionID: session.id,
            reason: "test_remote_pending_export_cleared"
        )

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        let entry = fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)
        XCTAssertFalse(badge.showPendingExport)
        XCTAssertFalse(badge.showLock)
        XCTAssertEqual(entry?.decision, "allow")
        XCTAssertEqual(entry?.reason, "status_exported")
        XCTAssertNil(entry?.block)
    }

    func testBadgeAndPendingDeliveryPreflightCannotDisagreeForExportedStatus() throws {
        let fixture = try makeCutoverFixture()
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let exportedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .exported,
            lastExportedSessionID: session.id
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([exportedRecord])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        let refreshed = try XCTUnwrap(fixture.appState.sessions(for: fixture.property.id).first { $0.id == session.id })
        XCTAssertFalse(badge.showPendingExport)
        XCTAssertFalse(fixture.appState.isPendingDelivery(refreshed))
        XCTAssertEqual(fixture.appState.latestPendingExportSession(for: fixture.property.id)?.id, nil)
        XCTAssertEqual(fixture.appState.pendingExportCountAcrossProperties(), 0)
    }

    func testForegroundRefreshKeepsRemoteDeliveredStateConsistent() throws {
        let fixture = try makeCutoverFixture()
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let exportedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .exported,
            lastExportedSessionID: session.id
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([exportedRecord])
        fixture.appState._debugRunForegroundCacheRefreshForTests()

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        let entry = fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)
        let refreshed = try XCTUnwrap(fixture.appState.sessions(for: fixture.property.id).first { $0.id == session.id })
        XCTAssertFalse(badge.showPendingExport)
        XCTAssertFalse(fixture.appState.isPendingDelivery(refreshed))
        XCTAssertEqual(entry?.decision, "allow")
        XCTAssertNotNil(refreshed.firstDeliveredAt)
    }

    func testPersistentDataReconciliationDoesNotRecurseOrLoop() async throws {
        let fixture = try makeCutoverFixture()
        await stabilizeAsyncFixtureAuthContext(fixture)
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let exportedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .exported,
            lastExportedSessionID: session.id
        )
        fixture.appState._debugReplacePropertyStatusCacheWithoutReconcileForTests([exportedRecord])

        fixture.appState._debugSchedulePersistentDataCacheRefreshForTests()
        await yieldMainActor(times: 6)

        let writesAfterConvergence = fixture.appState._debugDeliveredSessionStateReconciliationWriteCountForTests()
        let refreshed = try XCTUnwrap(deliveredSession(session.id, propertyID: fixture.property.id, localStore: fixture.localStore))
        XCTAssertEqual(writesAfterConvergence, 1)
        XCTAssertNotNil(refreshed.firstDeliveredAt)

        fixture.appState._debugSchedulePersistentDataCacheRefreshForTests()
        await yieldMainActor(times: 6)

        XCTAssertEqual(fixture.appState._debugDeliveredSessionStateReconciliationWriteCountForTests(), writesAfterConvergence)
    }

    func testForegroundRefreshCompletesWithoutHanging() throws {
        let fixture = try makeCutoverFixture()
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let exportedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .exported,
            lastExportedSessionID: session.id
        )
        fixture.appState._debugReplacePropertyStatusCacheWithoutReconcileForTests([exportedRecord])

        fixture.appState._debugRunForegroundCacheRefreshForTests()

        let refreshed = try XCTUnwrap(fixture.appState.sessions(for: fixture.property.id).first { $0.id == session.id })
        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        XCTAssertNotNil(refreshed.firstDeliveredAt)
        XCTAssertFalse(badge.showPendingExport)
        XCTAssertFalse(badge.showLock)
        XCTAssertLessThanOrEqual(fixture.appState._debugDeliveredSessionStateReconciliationWriteCountForTests(), 1)
    }

    func testDeviceBStartupConvergesDeliveredStateWithoutRepeatedWrites() async throws {
        let fixture = try makeCutoverFixture()
        await stabilizeAsyncFixtureAuthContext(fixture)
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let exportedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .exported,
            lastExportedSessionID: session.id
        )
        fixture.appState._debugReplacePropertyStatusCacheWithoutReconcileForTests([exportedRecord])

        fixture.appState._debugRunForegroundCacheRefreshForTests()
        fixture.appState._debugSchedulePersistentDataCacheRefreshForTests()
        await yieldMainActor(times: 8)

        let writesAfterStartup = fixture.appState._debugDeliveredSessionStateReconciliationWriteCountForTests()
        let visibleSession = await waitForVisibleSession(
            session.id,
            propertyID: fixture.property.id,
            appState: fixture.appState
        )
        let refreshed = try XCTUnwrap(visibleSession)
        XCTAssertEqual(writesAfterStartup, 1)
        XCTAssertNotNil(refreshed.exportedAt)
        XCTAssertNotNil(refreshed.firstDeliveredAt)
        XCTAssertEqual(fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)?.decision, "allow")

        fixture.appState._debugRunForegroundCacheRefreshForTests()
        fixture.appState._debugSchedulePersistentDataCacheRefreshForTests()
        await yieldMainActor(times: 8)

        XCTAssertEqual(fixture.appState._debugDeliveredSessionStateReconciliationWriteCountForTests(), writesAfterStartup)
    }

    func testOccupancyLockRemainsIndependentFromStalePendingSession() throws {
        let fixture = try makeCutoverFixture()
        let session = try seedCapturedPendingExportSession(
            propertyID: fixture.property.id,
            localStore: fixture.localStore
        )
        fixture.appState.refreshPropertySessionState(propertyID: fixture.property.id)
        let occupiedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: UUID(),
            ownerUserID: UUID(),
            ownerDeviceID: "other-device"
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([occupiedRecord])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)
        let entry = fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)
        XCTAssertFalse(badge.showPendingExport)
        XCTAssertTrue(badge.showLock)
        XCTAssertFalse(fixture.appState.isPendingDelivery(session))
        XCTAssertEqual(entry?.decision, "block")
        XCTAssertEqual(entry?.block?.blockContext, "occupied")
    }

    func testPropertyStatusBadgeIgnoresLegacyOccupancyWhenRowExists() throws {
        let fixture = try makeCutoverFixture()
        fixture.appState._debugSetPropertySessionOccupancyForTests(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            occupiedByUserID: UUID(),
            occupiedByDeviceID: "legacy-other-device",
            occupiedAt: Date()
        )
        let exportedRecord = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .exported,
            lastExportedSessionID: UUID()
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([exportedRecord])

        let badge = fixture.appState.propertyCardBadgeModel(for: fixture.property.id)

        XCTAssertEqual(badge.badgeSource, "property_status")
        XCTAssertFalse(badge.showDraft)
        XCTAssertFalse(badge.showLock)
        XCTAssertFalse(badge.showPendingExport)
        XCTAssertEqual(fixture.appState.draftPropertyCount(), 0)
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
        XCTAssertEqual(decision?.block?.ownerDescription, "Morgan Owner on device owner-de")
    }

    func testPropertyStatusEntryBlockUsesShortFriendlyFallbackOwnerDescription() throws {
        let fixture = try makeCutoverFixture()
        let ownerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: UUID(),
            ownerUserID: ownerID,
            ownerDeviceID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let decision = fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)

        XCTAssertEqual(decision?.decision, "block")
        XCTAssertEqual(
            decision?.block?.ownerDescription,
            "another signed-in user (11111111) on device aaaaaaaa"
        )
        XCTAssertFalse(decision?.block?.ownerDescription.contains(ownerID.uuidString) ?? true)
    }

    func testPropertyStatusEntryBlockUsesSignedInFallbackWhenUserUnknown() throws {
        let fixture = try makeCutoverFixture()
        let record = makeStatusRecord(
            propertyID: fixture.property.id,
            orgID: fixture.orgID,
            status: .occupied,
            activeSessionID: UUID(),
            ownerUserID: nil,
            ownerDeviceID: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
        )
        fixture.appState._debugReplacePropertyStatusCacheForTests([record])

        let decision = fixture.appState.evaluatePropertyStatusEntryPreflight(propertyID: fixture.property.id)

        XCTAssertEqual(decision?.decision, "block")
        XCTAssertEqual(decision?.block?.ownerDescription, "another signed-in user on device bbbbbbbb")
    }

    func testSessionEntryBlockMessageMapsPropertyStatusContext() throws {
        XCTAssertEqual(
            AppState.sessionEntryBlockMessage(
                for: AppState.SessionEntryCoordinationBlock(
                    ownerDescription: "owner@example.com",
                    lockedAt: Date(),
                    blockContext: "occupied"
                )
            ),
            "Property is currently occupied by owner@example.com."
        )
        XCTAssertEqual(
            AppState.sessionEntryBlockMessage(
                for: AppState.SessionEntryCoordinationBlock(
                    ownerDescription: "owner@example.com",
                    lockedAt: Date(),
                    blockContext: "draft"
                )
            ),
            "A draft is in progress by owner@example.com."
        )
        XCTAssertEqual(
            AppState.sessionEntryBlockMessage(
                for: AppState.SessionEntryCoordinationBlock(
                    ownerDescription: "owner@example.com",
                    lockedAt: Date(timeIntervalSinceReferenceDate: 809_255_700),
                    blockContext: "pending_export"
                ),
                lockedAtFormatter: { _ in "Aug 19, 9:15 AM" }
            ),
            "Locked by: owner@example.com\nPending since: Aug 19, 9:15 AM"
        )
        XCTAssertEqual(
            AppState.sessionEntryBlockMessage(
                for: AppState.SessionEntryCoordinationBlock(
                    ownerDescription: "another user",
                    lockedAt: nil,
                    blockContext: "pending_export"
                ),
                lockedAtFormatter: { _ in "Aug 19, 9:15 AM" }
            ),
            "Locked by: another user"
        )
        XCTAssertEqual(
            AppState.sessionEntryBlockMessage(
                for: AppState.SessionEntryCoordinationBlock(
                    ownerDescription: AppState.coordinationUnavailableLockMessage,
                    lockedAt: nil,
                    blockContext: "verification_failed"
                )
            ),
            AppState.coordinationUnavailableLockMessage
        )
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
        ownerDeviceID: String? = nil,
        heartbeatAt: Date? = Date(),
        updatedAt: Date = Date(),
        updatedBy: UUID? = nil
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
            heartbeatAt: heartbeatAt,
            updatedAt: updatedAt,
            updatedBy: updatedBy ?? ownerUserID,
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

    private func seedCapturedPendingExportSession(propertyID: UUID, localStore: LocalStore) throws -> Session {
        let session = try localStore.upsertSession(
            Session(
                id: UUID(),
                propertyID: propertyID,
                startedAt: Date(timeIntervalSinceReferenceDate: 200),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 220),
                exportedAt: nil,
                isSealed: true,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil
            )
        )
        try localStore.ensureSessionMetadata(for: session)
        var metadata = try localStore.loadSessionMetadata(propertyID: propertyID, sessionID: session.id)
        metadata.shots = [
            ShotMetadata(
                shotID: UUID(),
                propertyID: propertyID,
                sessionID: session.id,
                createdAt: Date(timeIntervalSinceReferenceDate: 201),
                updatedAt: Date(timeIntervalSinceReferenceDate: 201),
                building: "",
                elevation: "",
                detailType: "",
                angleIndex: 0,
                shotKey: "pending-export",
                isGuided: false,
                isFlagged: false,
                issueID: nil,
                issueStatus: nil,
                noteText: nil,
                noteCategory: nil,
                originalFilename: "pending.jpg",
                originalRelativePath: "Originals/pending.jpg",
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
            .appendingPathComponent("Originals/pending.jpg", isDirectory: false)
        try FileManager.default.createDirectory(
            at: originalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(to: originalURL)
        return session
    }

    private func yieldMainActor(times: Int) async {
        for _ in 0..<times {
            await MainActor.run {}
            await Task.yield()
        }
    }

    private func stabilizeAsyncFixtureAuthContext(_ fixture: CutoverFixture) async {
        applyStableOfflineFixtureContext(fixture)
        await yieldMainActor(times: 4)
        applyStableOfflineFixtureContext(fixture)
    }

    private func applyStableOfflineFixtureContext(_ fixture: CutoverFixture) {
        fixture.appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: fixture.orgID,
            ready: true,
            clientConfigured: false,
            authenticated: false,
            authenticationReady: true
        )
        fixture.appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(id: fixture.orgID, name: "Status Cutover Org", role: "owner")
            ],
            activeOrganizationID: fixture.orgID,
            ready: true
        )
        fixture.appState._debugRefreshPropertiesLocallyForTests()
    }

    private func deliveredSession(
        _ sessionID: UUID,
        propertyID: UUID,
        localStore: LocalStore
    ) throws -> Session? {
        try localStore.fetchSessions(propertyID: propertyID).first { $0.id == sessionID }
    }

    private func waitForVisibleSession(
        _ sessionID: UUID,
        propertyID: UUID,
        appState: AppState,
        timeout: TimeInterval = 2.0
    ) async -> Session? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let session = appState.sessions(for: propertyID).first(where: { $0.id == sessionID }) {
                return session
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return appState.sessions(for: propertyID).first { $0.id == sessionID }
    }
}
