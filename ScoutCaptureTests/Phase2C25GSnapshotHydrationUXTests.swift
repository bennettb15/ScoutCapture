import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C25GSnapshotHydrationUXTests: XCTestCase {
    private func makeDiagnostics(
        result: AppState.SessionSnapshotRestoreDiagnosticOutcome = .restorableMetadataCandidate,
        checksumVerified: Bool = true,
        rowObjectVerified: Bool = true,
        parentVerified: Bool = true,
        schemaVersion: Int? = 1,
        freshness: String = "equal",
        propertyID: UUID? = UUID(),
        sessionID: UUID? = UUID(),
        snapshotID: UUID? = UUID(),
        shotCount: Int? = 3,
        issueCount: Int? = 2,
        guidedCount: Int? = 1
    ) -> AppState.SessionSnapshotUploadDiagnostics {
        var diagnostics = AppState.SessionSnapshotUploadDiagnostics()
        diagnostics.lastRestoreDiagnosticsResult = result.rawValue
        diagnostics.lastRestoreDiagnosticsPropertyID = propertyID
        diagnostics.lastRestoreDiagnosticsSessionID = sessionID
        diagnostics.lastRestoreDiagnosticsSnapshotID = snapshotID
        diagnostics.lastRestoreDiagnosticsChecksumVerified = checksumVerified
        diagnostics.lastRestoreDiagnosticsRowObjectVerified = rowObjectVerified
        diagnostics.lastRestoreDiagnosticsParentRemoteVerified = parentVerified
        diagnostics.lastRestoreDiagnosticsSnapshotSchemaVersion = schemaVersion
        diagnostics.lastRestoreDiagnosticsFreshness = freshness
        diagnostics.lastRestoreDiagnosticsSnapshotShotCount = shotCount
        diagnostics.lastRestoreDiagnosticsSnapshotIssueCount = issueCount
        diagnostics.lastRestoreDiagnosticsSnapshotGuidedCount = guidedCount
        return diagnostics
    }

    private func policy(
        available: Bool = true,
        productionAllowed: Bool = false,
        mode: String = "diagnostics_only",
        scope: String = "local_or_staging_manual",
        blockedReason: String? = nil
    ) -> AppState.SessionSnapshotHydrationPolicyDiagnostics {
        AppState.SessionSnapshotHydrationPolicyDiagnostics(
            hydrationAvailable: available,
            productionHydrationAllowed: productionAllowed,
            hydrationMode: mode,
            hydrationScope: scope,
            productionHydrationBlockedReason: blockedReason
        )
    }

    func testHydrationConfirmationIsRequiredAndShowsTargetAndCounts() {
        let propertyID = UUID()
        let sessionID = UUID()
        let snapshotID = UUID()
        let confirmation = AppState.makeSessionSnapshotHydrationConfirmation(
            diagnostics: makeDiagnostics(
                propertyID: propertyID,
                sessionID: sessionID,
                snapshotID: snapshotID
            ),
            policy: policy()
        )

        XCTAssertTrue(confirmation.confirmationRequired)
        XCTAssertTrue(confirmation.canHydrate)
        XCTAssertNil(confirmation.blockedReason)
        XCTAssertEqual(confirmation.propertyIDText, propertyID.uuidString)
        XCTAssertEqual(confirmation.sessionIDText, sessionID.uuidString)
        XCTAssertEqual(confirmation.snapshotIDText, snapshotID.uuidString)
        XCTAssertEqual(confirmation.shotCountText, "3")
        XCTAssertEqual(confirmation.issueCountText, "2")
        XCTAssertEqual(confirmation.guidedCountText, "1")
        XCTAssertTrue(confirmation.messageText.contains("Hydration writes local metadata only."))
        XCTAssertTrue(confirmation.messageText.contains("Media files and original images are not restored or downloaded."))
    }

    func testBlockedRestoreStateDoesNotAllowHydrationConfirmation() {
        let confirmation = AppState.makeSessionSnapshotHydrationConfirmation(
            diagnostics: makeDiagnostics(result: .checksumFailed, checksumVerified: false),
            policy: policy()
        )

        XCTAssertTrue(confirmation.confirmationRequired)
        XCTAssertFalse(confirmation.canHydrate)
        XCTAssertEqual(confirmation.blockedReason, "checksum_failed")
        XCTAssertTrue(confirmation.messageText.contains("Blocked reason: checksum_failed"))
    }

    func testLocalNewerConflictCannotHydrateFromConfirmation() {
        let confirmation = AppState.makeSessionSnapshotHydrationConfirmation(
            diagnostics: makeDiagnostics(result: .localNewerConflict, freshness: "local_newer"),
            policy: policy()
        )

        XCTAssertFalse(confirmation.canHydrate)
        XCTAssertEqual(confirmation.blockedReason, "local_newer_conflict")
        XCTAssertTrue(confirmation.messageText.contains("Blocked reason: local_newer_conflict"))
    }

    func testProductionBlockedMessageIsClear() {
        let confirmation = AppState.makeSessionSnapshotHydrationConfirmation(
            diagnostics: makeDiagnostics(),
            policy: policy(
                available: false,
                productionAllowed: false,
                mode: "blocked_by_default",
                scope: "none",
                blockedReason: "production_hydration_gate_disabled"
            )
        )

        XCTAssertFalse(confirmation.canHydrate)
        XCTAssertEqual(confirmation.blockedReason, "production_hydration_gate_disabled")
        XCTAssertTrue(confirmation.messageText.contains("Blocked reason: production_hydration_gate_disabled"))
        XCTAssertTrue(confirmation.messageText.contains("Canonical reads, export, seal, sync, media, and iCloud behavior are unchanged."))
    }

    func testRestoreDiagnosticsRemainReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C25G-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let appState = AppState(
            localStore: LocalStore(testStorageRootURL: root),
            userDefaults: UserDefaults(suiteName: "ScoutCapture-2C25G-\(UUID().uuidString)") ?? .standard,
            environment: [
                "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
                "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key"
            ],
            sessionSnapshotRowsFetchOverride: { _, _, _ in [] },
            sessionSnapshotStorageDownloadOverride: { _, _ in Data() },
            disableCloudBackupForTests: true
        )

        let diagnostics = await appState.validateLatestSessionSnapshotRestoreDiagnostics()

        XCTAssertEqual(diagnostics.result, .noSnapshotFound)
        XCTAssertNil(appState.localDiagnostics.sessionSnapshotUpload.lastHydrationAt)
        XCTAssertFalse(appState.localDiagnostics.sessionSnapshotUpload.lastHydrationAllowed)
    }
}
