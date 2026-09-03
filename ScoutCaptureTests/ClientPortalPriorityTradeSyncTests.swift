import XCTest
@testable import ScoutCapture

final class ClientPortalPriorityTradeSyncTests: XCTestCase {
    private let older = Date(timeIntervalSinceReferenceDate: 1_000)
    private let newer = Date(timeIntervalSinceReferenceDate: 2_000)
    private let newest = Date(timeIntervalSinceReferenceDate: 3_000)

    private typealias PortalActivityRow = (
        id: UUID,
        propertyID: UUID?,
        observationID: UUID?,
        activityType: String,
        fromValue: String?,
        note: String?,
        createdAt: Date,
        deletedAt: Date?
    )

    private func makePortalActivityRow(
        id: UUID = UUID(),
        propertyID: UUID?,
        observationID: UUID?,
        activityType: String,
        fromValue: String? = nil,
        note: String? = nil,
        createdAt: Date,
        deletedAt: Date? = nil
    ) -> PortalActivityRow {
        (
            id: id,
            propertyID: propertyID,
            observationID: observationID,
            activityType: activityType,
            fromValue: fromValue,
            note: note,
            createdAt: createdAt,
            deletedAt: deletedAt
        )
    }

    private func makePortalActivityRowWithShotID(
        id: UUID = UUID(),
        propertyID: UUID?,
        observationID: UUID?,
        shotID: UUID?,
        activityType: String,
        fromValue: String? = nil,
        note: String? = nil,
        createdAt: Date,
        deletedAt: Date? = nil
    ) -> (
        id: UUID,
        propertyID: UUID?,
        observationID: UUID?,
        shotID: UUID?,
        activityType: String,
        fromValue: String?,
        note: String?,
        createdAt: Date,
        deletedAt: Date?
    ) {
        (
            id: id,
            propertyID: propertyID,
            observationID: observationID,
            shotID: shotID,
            activityType: activityType,
            fromValue: fromValue,
            note: note,
            createdAt: createdAt,
            deletedAt: deletedAt
        )
    }

    private func makeStore() throws -> (store: LocalStore, property: Property) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-PortalOverlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LocalStore(testStorageRootURL: root)
        let property = try store.createProperty(Property(id: UUID(), orgId: UUID(), name: "Portal Overlay Property"))
        return (store, property)
    }

    private func makeObservation(
        id: UUID = UUID(),
        propertyID: UUID,
        status: Observation.Status = .active,
        priority: String? = "Medium",
        trade: String? = "Paint",
        building: String? = "B1",
        elevation: String? = "North",
        detailType: String? = "Window"
    ) -> Observation {
        Observation(
            id: id,
            propertyID: propertyID,
            sessionID: UUID(),
            createdAt: older,
            updatedAt: older,
            statement: "Cracked pane",
            status: status,
            building: building,
            targetElevation: elevation,
            detailType: detailType,
            priority: priority,
            trade: trade,
            currentReason: "Cracked pane"
        )
    }

    private func makeCompletedFlaggedSessionMetadata(
        propertyID: UUID,
        sessionID: UUID,
        issueID: UUID,
        shotID: UUID = UUID(),
        priority: String?,
        trade: String?,
        issueStatus: String = "active"
    ) -> SessionMetadata {
        let shot = ShotMetadata(
            shotID: shotID,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: older,
            updatedAt: older,
            building: "B1",
            elevation: "North",
            detailType: "Window",
            angleIndex: 1,
            trade: trade,
            priority: priority,
            shotKey: "b1-north-window-1",
            isGuided: false,
            isFlagged: true,
            issueID: issueID,
            issueStatus: issueStatus,
            noteText: "Cracked pane",
            noteCategory: "general",
            originalFilename: "flagged.jpg",
            originalRelativePath: "Originals/flagged.jpg",
            originalByteSize: 123,
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
            issueStatus: issueStatus,
            currentReason: "Cracked pane",
            firstSeenAt: older,
            lastSeenAt: older,
            lastCaptureSessionId: sessionID,
            detailNote: "Cracked pane",
            shotKey: shot.shotKey
        )
        return SessionMetadata(
            schemaVersion: 12,
            propertyID: propertyID,
            sessionID: sessionID,
            propertyNameAtCapture: "Portal Overlay Property",
            propertyNameAtExport: nil,
            startedAt: older,
            endedAt: newer,
            status: .completed,
            isBaselineSession: false,
            exportedAt: newer,
            isSealed: true,
            appVersion: "test-app",
            deviceModel: "test-device",
            osVersion: "test-os",
            shots: [shot],
            issues: [issue]
        )
    }

    func testPortalPriorityChangeSyncsIntoFutureActiveIssue() throws {
        let fixture = try makeStore()
        let issueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(id: issueID, propertyID: fixture.property.id, priority: "Low")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: issueID,
                    propertyID: fixture.property.id,
                    priority: "Critical",
                    updatedAt: newer
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(updated.priority, "Critical")
        XCTAssertEqual(updated.trade, "Paint")
    }

    func testWebsitePunchlistActivityCriticalPriorityOverridesObservationPriority() throws {
        let propertyID = UUID()
        let issueID = UUID()

        let overlays = AppState.portalPunchlistOperationalOverlaysTestOnly(
            propertyID: propertyID,
            observationID: issueID,
            observationPriority: "High",
            observationTrade: "paint",
            activityRows: [
                (activityType: "priority_changed", toValue: "critical", createdAt: newer)
            ]
        )

        let overlay = try XCTUnwrap(overlays.first)
        XCTAssertEqual(overlay.issueID, issueID)
        XCTAssertEqual(overlay.priority, "Critical")
        XCTAssertEqual(overlay.trade, "paint")
    }

    func testWebsitePunchlistActivityHighPriorityCanReplaceCritical() throws {
        let propertyID = UUID()
        let issueID = UUID()

        let overlays = AppState.portalPunchlistOperationalOverlaysTestOnly(
            propertyID: propertyID,
            observationID: issueID,
            observationPriority: "Critical",
            observationTrade: "paint",
            activityRows: [
                (activityType: "priority_changed", toValue: "critical", createdAt: older),
                (activityType: "priority_changed", toValue: "high", createdAt: newer)
            ]
        )

        let overlay = try XCTUnwrap(overlays.first)
        XCTAssertEqual(overlay.priority, "High")
    }

    func testPortalTradeChangeSyncsIntoFutureActiveIssue() throws {
        let fixture = try makeStore()
        let issueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(id: issueID, propertyID: fixture.property.id, trade: "Paint")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: issueID,
                    propertyID: fixture.property.id,
                    trade: "Electrical",
                    updatedAt: newer
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(updated.priority, "Medium")
        XCTAssertEqual(updated.trade, "Electrical")
    }

    func testWebsitePunchlistActivityTradeOverridesObservationTrade() throws {
        let propertyID = UUID()
        let issueID = UUID()

        let overlays = AppState.portalPunchlistOperationalOverlaysTestOnly(
            propertyID: propertyID,
            observationID: issueID,
            observationPriority: "Medium",
            observationTrade: "paint",
            activityRows: [
                (activityType: "trade_changed", toValue: "electrical", createdAt: newer)
            ]
        )

        let overlay = try XCTUnwrap(overlays.first)
        XCTAssertEqual(overlay.priority, "Medium")
        XCTAssertEqual(overlay.trade, "electrical")
    }

    func testTradeOptionsDeduplicateCaseAndPreferBuiltinCanonicalCasing() {
        let options = ContentView.canonicalTradeOptions(["HVAC", "hvac", "  Hvac  "])

        XCTAssertEqual(options, ["HVAC"])
    }

    func testTradeOptionsNormalizeLandscapingAndHVACCasing() {
        let options = ContentView.canonicalTradeOptions(["landscaping", "HVAC", "hvac"])

        XCTAssertEqual(options, ["Landscaping", "HVAC"])
    }

    func testPortalSyncedBuiltinTradePersistsCanonicalCasing() throws {
        let fixture = try makeStore()
        let issueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(id: issueID, propertyID: fixture.property.id, trade: "Paint")
        )

        _ = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: issueID,
                    propertyID: fixture.property.id,
                    trade: "hvac",
                    updatedAt: newer
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(updated.trade, "HVAC")
    }

    func testPortalSyncedBuiltinTradeCorrectsPriorLowercaseLocalCasing() throws {
        let fixture = try makeStore()
        let issueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(id: issueID, propertyID: fixture.property.id, trade: "hvac")
        )

        _ = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: issueID,
                    propertyID: fixture.property.id,
                    trade: "hvac",
                    updatedAt: newer
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(updated.trade, "HVAC")
    }

    func testArmedIssueTradeRestoresPreviousStickyTradeWhenNotManuallyChanged() {
        let restored = ContentView.restoredStickyTradeAfterClearingArmedIssueScope(
            currentTrade: "hvac",
            previousStickyTrade: "Roofing",
            armedIssueTradeManuallyChanged: false,
            preferredOptions: ["Roofing", "HVAC"]
        )

        XCTAssertEqual(restored, "Roofing")
    }

    func testManualTradeChangeWhileArmedRemainsSticky() {
        let restored = ContentView.restoredStickyTradeAfterClearingArmedIssueScope(
            currentTrade: "plumbing",
            previousStickyTrade: "Roofing",
            armedIssueTradeManuallyChanged: true,
            preferredOptions: ["Roofing", "Plumbing"]
        )

        XCTAssertEqual(restored, "Plumbing")
    }

    func testNewerPortalActivityAfterCompletionOverridesPriorSyncedValues() throws {
        let fixture = try makeStore()
        let issueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(
                id: issueID,
                propertyID: fixture.property.id,
                priority: "High",
                trade: "HVAC",
                building: "B1",
                elevation: "North",
                detailType: "Window"
            )
        )
        let completionTime = Date(timeIntervalSinceReferenceDate: 2_500)
        let postCompletionPriorityChange = Date(timeIntervalSinceReferenceDate: 3_000)
        let postCompletionTradeChange = Date(timeIntervalSinceReferenceDate: 3_100)

        let overlays = AppState.portalPunchlistOperationalOverlaysTestOnly(
            propertyID: fixture.property.id,
            observationID: issueID,
            observationPriority: "High",
            observationTrade: "HVAC",
            activityRows: [
                (activityType: "completion_submitted", toValue: nil, createdAt: completionTime),
                (activityType: "priority_changed", toValue: "critical", createdAt: postCompletionPriorityChange),
                (activityType: "trade_changed", toValue: "Landscaping", createdAt: postCompletionTradeChange)
            ]
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: overlays
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(updated.status, .active)
        XCTAssertEqual(updated.priority, "Critical")
        XCTAssertEqual(updated.trade, "Landscaping")
    }

    func testPortalPriorityRemainsAfterDelayedSnapshotReferenceMerge() throws {
        let fixture = try makeStore()
        let sessionID = UUID()
        let issueID = UUID()
        _ = try fixture.store.upsertSession(
            Session(
                id: sessionID,
                propertyID: fixture.property.id,
                startedAt: older,
                status: .completed,
                endedAt: newer,
                exportedAt: newer,
                isSealed: true
            )
        )
        _ = try fixture.store.createObservation(
            makeObservation(
                id: issueID,
                propertyID: fixture.property.id,
                priority: "Critical",
                trade: "Landscaping"
            )
        )
        let olderSnapshotMetadata = makeCompletedFlaggedSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: sessionID,
            issueID: issueID,
            priority: "High",
            trade: "HVAC"
        )

        try fixture.store.mergeRemoteFlaggedReferenceObservations(
            propertyID: fixture.property.id,
            sessionID: sessionID,
            metadata: olderSnapshotMetadata
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(updated.status, .active)
        XCTAssertEqual(updated.priority, "Critical")
        XCTAssertEqual(updated.trade, "Landscaping")
    }

    func testOlderLocalPackagePriorityCannotOverwriteNewerPortalPriority() throws {
        let fixture = try makeStore()
        let sessionID = UUID()
        let issueID = UUID()
        _ = try fixture.store.upsertSession(Session(id: sessionID, propertyID: fixture.property.id))
        _ = try fixture.store.createObservation(
            makeObservation(
                id: issueID,
                propertyID: fixture.property.id,
                priority: "High",
                trade: "HVAC"
            )
        )

        _ = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: issueID,
                    propertyID: fixture.property.id,
                    priority: "Critical",
                    trade: "landscaping",
                    updatedAt: newer
                )
            ]
        )
        try fixture.store.mergeRemoteFlaggedReferenceObservations(
            propertyID: fixture.property.id,
            sessionID: sessionID,
            metadata: makeCompletedFlaggedSessionMetadata(
                propertyID: fixture.property.id,
                sessionID: sessionID,
                issueID: issueID,
                priority: "High",
                trade: "HVAC"
            )
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(updated.priority, "Critical")
        XCTAssertEqual(updated.trade, "Landscaping")
    }

    func testNoPortalOverrideKeepsScoutCaptureOriginalValues() throws {
        let fixture = try makeStore()
        let issueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(id: issueID, propertyID: fixture.property.id, priority: "High", trade: "Roofing")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: issueID,
                    propertyID: fixture.property.id,
                    updatedAt: newer
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(updated.priority, "High")
        XCTAssertEqual(updated.trade, "Roofing")
    }

    func testResolvedIssueDoesNotReappearActiveBecauseOfPriorityTradeSync() throws {
        let fixture = try makeStore()
        let issueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(id: issueID, propertyID: fixture.property.id, status: .resolved, priority: "Medium", trade: "Paint")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: issueID,
                    propertyID: fixture.property.id,
                    status: .active,
                    priority: "Critical",
                    trade: "Plumbing",
                    updatedAt: newer
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.skippedResolvedCount, 1)
        XCTAssertEqual(updated.status, .resolved)
        XCTAssertEqual(updated.priority, "Medium")
        XCTAssertEqual(updated.trade, "Paint")
    }

    func testWebsitePunchlistActivityResolvedStatusPreventsPriorityOverlayApply() throws {
        let fixture = try makeStore()
        let issueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(id: issueID, propertyID: fixture.property.id, priority: "High", trade: "Paint")
        )
        let overlays = AppState.portalPunchlistOperationalOverlaysTestOnly(
            propertyID: fixture.property.id,
            observationID: issueID,
            observationPriority: "High",
            observationTrade: "Paint",
            activityRows: [
                (activityType: "priority_changed", toValue: "critical", createdAt: older),
                (activityType: "status_changed", toValue: "resolved", createdAt: newer)
            ]
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: overlays
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.skippedResolvedCount, 1)
        XCTAssertEqual(updated.status, .active)
        XCTAssertEqual(updated.priority, "High")
    }

    func testMissingIssueIDMatchesStableLocationIdentity() throws {
        let fixture = try makeStore()
        _ = try fixture.store.createObservation(
            makeObservation(propertyID: fixture.property.id, priority: "Low", trade: "Paint")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: nil,
                    propertyID: fixture.property.id,
                    priority: "High",
                    trade: "Electrical",
                    updatedAt: newer,
                    building: "B1",
                    targetElevation: "North",
                    detailType: "Window",
                    angleIndex: 1
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(updated.priority, "High")
        XCTAssertEqual(updated.trade, "Electrical")
    }

    func testIssueIDMissCanMatchUniqueStableLocationIdentity() throws {
        let fixture = try makeStore()
        let localIssueID = UUID()
        _ = try fixture.store.createObservation(
            makeObservation(id: localIssueID, propertyID: fixture.property.id, priority: "High", trade: "Paint")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: UUID(),
                    propertyID: fixture.property.id,
                    priority: "Critical",
                    trade: "Electrical",
                    updatedAt: newer,
                    building: "B1",
                    targetElevation: "North",
                    detailType: "Window",
                    angleIndex: 1
                )
            ]
        )

        let updated = try XCTUnwrap(try fixture.store.fetchObservations(propertyID: fixture.property.id).first)
        XCTAssertEqual(updated.id, localIssueID)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(updated.priority, "Critical")
        XCTAssertEqual(updated.trade, "Electrical")
    }

    func testAmbiguousLocationMatchDoesNotOverwriteLocalMetadata() throws {
        let fixture = try makeStore()
        _ = try fixture.store.createObservation(
            makeObservation(propertyID: fixture.property.id, priority: "Low", trade: "Paint")
        )
        _ = try fixture.store.createObservation(
            makeObservation(propertyID: fixture.property.id, priority: "High", trade: "Carpentry")
        )

        let result = try fixture.store.applyPortalPunchlistOperationalOverlays(
            propertyID: fixture.property.id,
            overlays: [
                PortalPunchlistOperationalOverlay(
                    issueID: nil,
                    propertyID: fixture.property.id,
                    priority: "Critical",
                    trade: "Electrical",
                    updatedAt: newer,
                    building: "B1",
                    targetElevation: "North",
                    detailType: "Window",
                    angleIndex: 1
                )
            ]
        )

        let observations = try fixture.store.fetchObservations(propertyID: fixture.property.id)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.skippedAmbiguousCount, 1)
        XCTAssertEqual(Set(observations.compactMap(\.priority)), Set(["Low", "High"]))
        XCTAssertEqual(Set(observations.compactMap(\.trade)), Set(["Paint", "Carpentry"]))
    }

    func testActiveIssueWithNoPortalNotesProducesNoNoteCount() {
        let propertyID = UUID()
        let issueID = UUID()

        let notes = AppState.portalPunchlistNotesByIssueIDTestOnly(
            propertyID: propertyID,
            issueIDs: [issueID],
            activityRows: []
        )

        XCTAssertNil(notes[issueID])
    }

    func testActiveIssueWithOnePortalNoteProducesIconCount() {
        let propertyID = UUID()
        let issueID = UUID()

        let notes = AppState.portalPunchlistNotesByIssueIDTestOnly(
            propertyID: propertyID,
            issueIDs: [issueID],
            activityRows: [
                makePortalActivityRow(
                    propertyID: propertyID,
                    observationID: issueID,
                    activityType: "note_added",
                    note: "Please review this window.",
                    createdAt: older
                )
            ]
        )

        XCTAssertEqual(notes[issueID]?.count, 1)
        XCTAssertEqual(notes[issueID]?.first?.note, "Please review this window.")
    }

    func testMultiplePortalNotesUseNewestFirstOrder() {
        let propertyID = UUID()
        let issueID = UUID()

        let notes = AppState.portalPunchlistNotesByIssueIDTestOnly(
            propertyID: propertyID,
            issueIDs: [issueID],
            activityRows: [
                makePortalActivityRow(
                    propertyID: propertyID,
                    observationID: issueID,
                    activityType: "note_added",
                    note: "Older note",
                    createdAt: older
                ),
                makePortalActivityRow(
                    propertyID: propertyID,
                    observationID: issueID,
                    activityType: "note_added",
                    note: "Newer note",
                    createdAt: newest
                )
            ]
        )

        XCTAssertEqual(notes[issueID]?.map(\.note), ["Newer note", "Older note"])
    }

    func testRejectedCompletionNoteIsExcludedFromPortalNotes() {
        let propertyID = UUID()
        let issueID = UUID()
        let submissionID = UUID()

        let notes = AppState.portalPunchlistNotesByIssueIDTestOnly(
            propertyID: propertyID,
            issueIDs: [issueID],
            activityRows: [
                makePortalActivityRow(
                    id: submissionID,
                    propertyID: propertyID,
                    observationID: issueID,
                    activityType: "completion_submitted",
                    note: "Completion needs review.",
                    createdAt: older
                ),
                makePortalActivityRow(
                    propertyID: propertyID,
                    observationID: issueID,
                    activityType: "completion_rejected",
                    fromValue: submissionID.uuidString,
                    note: "Rejected.",
                    createdAt: newer
                )
            ]
        )

        XCTAssertNil(notes[issueID])
    }

    func testApprovedCompletionSubmissionNoteIsIncludedInPortalNotes() {
        let propertyID = UUID()
        let issueID = UUID()
        let submissionID = UUID()

        let notes = AppState.portalPunchlistNotesByIssueIDTestOnly(
            propertyID: propertyID,
            issueIDs: [issueID],
            activityRows: [
                makePortalActivityRow(
                    id: submissionID,
                    propertyID: propertyID,
                    observationID: issueID,
                    activityType: "completion_submitted",
                    note: "Completed with new sealant.",
                    createdAt: older
                ),
                makePortalActivityRow(
                    propertyID: propertyID,
                    observationID: issueID,
                    activityType: "completion_approved",
                    fromValue: submissionID.uuidString,
                    note: "Approved.",
                    createdAt: newer
                )
            ]
        )

        XCTAssertEqual(notes[issueID]?.count, 1)
        XCTAssertEqual(notes[issueID]?.first?.note, "Completed with new sealant.")
        XCTAssertEqual(notes[issueID]?.first?.isCompletionNote, true)
    }

    func testUnrelatedIssueAndPropertyNotesDoNotAppear() {
        let propertyID = UUID()
        let otherPropertyID = UUID()
        let issueID = UUID()
        let otherIssueID = UUID()

        let notes = AppState.portalPunchlistNotesByIssueIDTestOnly(
            propertyID: propertyID,
            issueIDs: [issueID],
            activityRows: [
                makePortalActivityRow(
                    propertyID: propertyID,
                    observationID: issueID,
                    activityType: "note_added",
                    note: "Visible note",
                    createdAt: newest
                ),
                makePortalActivityRow(
                    propertyID: propertyID,
                    observationID: otherIssueID,
                    activityType: "note_added",
                    note: "Wrong issue",
                    createdAt: newer
                ),
                makePortalActivityRow(
                    propertyID: otherPropertyID,
                    observationID: issueID,
                    activityType: "note_added",
                    note: "Wrong property",
                    createdAt: older
                )
            ]
        )

        XCTAssertEqual(notes[issueID]?.map(\.note), ["Visible note"])
        XCTAssertNil(notes[otherIssueID])
    }

    func testPortalNotesMatchUniqueStableLocationWhenIssueIDDiffers() {
        let propertyID = UUID()
        let localIssueID = UUID()
        let remoteIssueID = UUID()
        let remoteShotID = UUID()

        let notes = AppState.portalPunchlistNotesByIssueIDTestOnly(
            propertyID: propertyID,
            localIssueRows: [
                (
                    id: localIssueID,
                    propertyID: propertyID,
                    status: .active,
                    linkedShotID: nil,
                    shotIDs: [],
                    building: "B1",
                    targetElevation: "North",
                    detailType: "Window"
                )
            ],
            activityRows: [
                makePortalActivityRowWithShotID(
                    propertyID: propertyID,
                    observationID: remoteIssueID,
                    shotID: remoteShotID,
                    activityType: "note_added",
                    note: "Website note on remote issue.",
                    createdAt: newer
                )
            ],
            remoteShotRows: [
                (
                    id: remoteShotID,
                    issueID: remoteIssueID,
                    propertyID: propertyID,
                    building: "B1",
                    elevation: "North",
                    detailType: "Window",
                    angleIndex: 1,
                    shotKey: nil
                )
            ]
        )

        XCTAssertEqual(notes[localIssueID]?.map(\.note), ["Website note on remote issue."])
        XCTAssertNil(notes[remoteIssueID])
    }

    func testPortalNotesDoNotUseAmbiguousStableLocationFallback() {
        let propertyID = UUID()
        let firstLocalIssueID = UUID()
        let secondLocalIssueID = UUID()
        let remoteIssueID = UUID()
        let remoteShotID = UUID()

        let notes = AppState.portalPunchlistNotesByIssueIDTestOnly(
            propertyID: propertyID,
            localIssueRows: [
                (
                    id: firstLocalIssueID,
                    propertyID: propertyID,
                    status: .active,
                    linkedShotID: nil,
                    shotIDs: [],
                    building: "B1",
                    targetElevation: "North",
                    detailType: "Window"
                ),
                (
                    id: secondLocalIssueID,
                    propertyID: propertyID,
                    status: .active,
                    linkedShotID: nil,
                    shotIDs: [],
                    building: "B1",
                    targetElevation: "North",
                    detailType: "Window"
                )
            ],
            activityRows: [
                makePortalActivityRowWithShotID(
                    propertyID: propertyID,
                    observationID: remoteIssueID,
                    shotID: remoteShotID,
                    activityType: "note_added",
                    note: "Ambiguous note.",
                    createdAt: newer
                )
            ],
            remoteShotRows: [
                (
                    id: remoteShotID,
                    issueID: remoteIssueID,
                    propertyID: propertyID,
                    building: "B1",
                    elevation: "North",
                    detailType: "Window",
                    angleIndex: 1,
                    shotKey: nil
                )
            ]
        )

        XCTAssertNil(notes[firstLocalIssueID])
        XCTAssertNil(notes[secondLocalIssueID])
    }

    func testPortalNotesPreferExactIssueIDOverLocationFallback() {
        let propertyID = UUID()
        let exactLocalIssueID = UUID()
        let locationLocalIssueID = UUID()
        let remoteShotID = UUID()

        let notes = AppState.portalPunchlistNotesByIssueIDTestOnly(
            propertyID: propertyID,
            localIssueRows: [
                (
                    id: exactLocalIssueID,
                    propertyID: propertyID,
                    status: .active,
                    linkedShotID: nil,
                    shotIDs: [],
                    building: "B2",
                    targetElevation: "South",
                    detailType: "Door"
                ),
                (
                    id: locationLocalIssueID,
                    propertyID: propertyID,
                    status: .active,
                    linkedShotID: nil,
                    shotIDs: [],
                    building: "B1",
                    targetElevation: "North",
                    detailType: "Window"
                )
            ],
            activityRows: [
                makePortalActivityRowWithShotID(
                    propertyID: propertyID,
                    observationID: exactLocalIssueID,
                    shotID: remoteShotID,
                    activityType: "note_added",
                    note: "Exact issue note.",
                    createdAt: newer
                )
            ],
            remoteShotRows: [
                (
                    id: remoteShotID,
                    issueID: exactLocalIssueID,
                    propertyID: propertyID,
                    building: "B1",
                    elevation: "North",
                    detailType: "Window",
                    angleIndex: 1,
                    shotKey: nil
                )
            ]
        )

        XCTAssertEqual(notes[exactLocalIssueID]?.map(\.note), ["Exact issue note."])
        XCTAssertNil(notes[locationLocalIssueID])
    }
}
