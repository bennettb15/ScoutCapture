import XCTest
@testable import ScoutCapture

final class Phase2C26HNormalizedParityRepairPlanningTests: XCTestCase {
    private let orgID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let propertyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func canonicalDiagnostics(
        result: AppState.CanonicalReadDiagnosticResult = .remoteMatchesLocal,
        parentOrgConsistent: Bool? = true,
        parentPropertyConsistent: Bool? = true,
        localShotCount: Int? = 2,
        remoteShotCount: Int? = 2,
        localIssueObservationCount: Int? = 1,
        remoteIssueObservationCount: Int? = 1,
        remotePropertyFound: Bool = true,
        remoteSessionFound: Bool = true,
        localSessionFound: Bool = true,
        countParity: Bool? = true
    ) -> AppState.CanonicalReadDiagnosticsResult {
        AppState.CanonicalReadDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            propertyID: propertyID,
            sessionID: sessionID,
            activeOrganizationID: orgID,
            result: result,
            remotePropertyFound: remotePropertyFound,
            remoteSessionFound: remoteSessionFound,
            localPropertyFound: true,
            localSessionFound: localSessionFound,
            countParity: countParity,
            statusParity: true,
            parentOrgConsistent: parentOrgConsistent,
            parentPropertyConsistent: parentPropertyConsistent,
            localShotCount: localShotCount,
            remoteShotCount: remoteShotCount,
            localIssueObservationCount: localIssueObservationCount,
            remoteIssueObservationCount: remoteIssueObservationCount,
            localGuidedCount: 0,
            remoteGuidedCount: nil,
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_900),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_900),
            remoteRevision: 12,
            remoteFreshnessAgeSeconds: 100,
            canonicalRecommendation: "local_first_block_canonical_read",
            blockedReason: nil,
            noBehaviorChangedText: "read only"
        )
    }

    func testParentOrgDivergenceRequiresLineageReconciliationAndBlocksReplay() {
        let report = AppState.makeNormalizedParityGapReport(
            canonicalDiagnostics: canonicalDiagnostics(
                result: .parentMismatch,
                parentOrgConsistent: false,
                localShotCount: 3,
                remoteShotCount: 0,
                localIssueObservationCount: 2,
                remoteIssueObservationCount: 0,
                countParity: false
            )
        )

        XCTAssertTrue(report.taxonomy.contains(.parentOrgDivergence))
        XCTAssertTrue(report.repairStrategies.contains(.lineageReconciliation))
        XCTAssertTrue(report.repairStrategies.contains(.noOpBlock))
        XCTAssertEqual(report.lineageConfidence, "blocked")
        XCTAssertEqual(report.replayEligibility, "blocked_until_parent_lineage_reconciled")
        XCTAssertEqual(report.repairRolloutPhase, "diagnostics_only")
    }

    func testMissingRemoteParentsClassifyRemoteMissingAndManualBackfill() {
        let report = AppState.makeNormalizedParityGapReport(
            canonicalDiagnostics: canonicalDiagnostics(
                result: .remoteMissing,
                remotePropertyFound: false,
                remoteSessionFound: false,
                countParity: nil
            )
        )

        XCTAssertTrue(report.taxonomy.contains(.remoteMissing))
        XCTAssertTrue(report.taxonomy.contains(.legacyLocalOnlySession))
        XCTAssertTrue(report.repairStrategies.contains(.remoteBackfill))
        XCTAssertEqual(report.replayEligibility, "requires_manual_parent_backfill_plan")
        XCTAssertEqual(report.repairRolloutPhase, "allowlisted_manual_repair_tooling")
    }

    func testMissingRemoteChildrenRecommendChildRegenerationAndReplayPolicyOnly() {
        let report = AppState.makeNormalizedParityGapReport(
            canonicalDiagnostics: canonicalDiagnostics(
                result: .divergentConflict,
                localShotCount: 4,
                remoteShotCount: 1,
                localIssueObservationCount: 2,
                remoteIssueObservationCount: 0,
                countParity: false
            )
        )

        XCTAssertTrue(report.taxonomy.contains(.missingRemoteChildren) == false)
        XCTAssertTrue(report.taxonomy.contains(.partialShadowWrite))
        XCTAssertTrue(report.repairStrategies.contains(.shadowWriteReplay))
        XCTAssertEqual(report.missingChildCount, 5)
        XCTAssertLessThan(report.shadowWriteCoverageScore, 1)
        XCTAssertEqual(report.replayEligibility, "candidate_for_test_only_shadow_write_replay_after_snapshot_verification")
        XCTAssertEqual(report.repairRolloutPhase, "test_only_replay_backfill")
    }

    func testFullyMissingRemoteChildrenRecommendChildRowRegeneration() {
        let report = AppState.makeNormalizedParityGapReport(
            canonicalDiagnostics: canonicalDiagnostics(
                result: .divergentConflict,
                localShotCount: 2,
                remoteShotCount: 0,
                localIssueObservationCount: 1,
                remoteIssueObservationCount: 0,
                countParity: false
            )
        )

        XCTAssertTrue(report.taxonomy.contains(.missingRemoteChildren))
        XCTAssertTrue(report.repairStrategies.contains(.childRowRegeneration))
        XCTAssertTrue(report.repairStrategies.contains(.remoteBackfill))
        XCTAssertEqual(report.missingChildCount, 3)
    }

    func testRepairReportIncludesSafetyRulesAndNoExecutionLanguage() {
        let report = AppState.makeNormalizedParityGapReport(
            canonicalDiagnostics: canonicalDiagnostics(result: .remoteMatchesLocal)
        )
        let text = AppState.normalizedParityGapReportText(report)

        XCTAssertTrue(report.taxonomy.isEmpty)
        XCTAssertFalse(report.parityRepairToolingRecommended)
        XCTAssertEqual(report.repairRolloutPhase, "canonical_read_candidate_readiness")
        XCTAssertTrue(report.repairSafetyRules.contains("no_blind_overwrite"))
        XCTAssertTrue(report.repairSafetyRules.contains("operator_manual_gating_required"))
        XCTAssertTrue(report.diagnosticsBeforeRepair.contains("parity_completeness_score"))
        XCTAssertTrue(text.contains("No behavior changed"))
        XCTAssertTrue(text.contains("does not switch canonical reads"))
        XCTAssertTrue(text.contains("repair parity"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("auth_token="))
        XCTAssertFalse(text.contains("/Users/"))
    }
}
