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
            deleteEligibilityDecision: "blocked_by_draft_badge"
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
            deleteEligibilityDecision: "blocked_by_draft_badge"
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
    }
}
