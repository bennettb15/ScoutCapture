import XCTest
@testable import ScoutCapture

final class Phase2C26JParityReplayValidationTests: XCTestCase {
    private let orgID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let propertyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func canonicalDiagnostics(
        result: AppState.CanonicalReadDiagnosticResult,
        recommendation: String,
        parentOrgConsistent: Bool? = true,
        parentPropertyConsistent: Bool? = true,
        localShotCount: Int = 4,
        remoteShotCount: Int,
        localIssueObservationCount: Int = 2,
        remoteIssueObservationCount: Int,
        countParity: Bool? = false
    ) -> AppState.CanonicalReadDiagnosticsResult {
        AppState.CanonicalReadDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 4_000),
            propertyID: propertyID,
            sessionID: sessionID,
            activeOrganizationID: orgID,
            result: result,
            remotePropertyFound: true,
            remoteSessionFound: true,
            localPropertyFound: true,
            localSessionFound: true,
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
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 3_900),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 3_900),
            remoteRevision: 32,
            remoteFreshnessAgeSeconds: 100,
            canonicalRecommendation: recommendation,
            blockedReason: nil,
            noBehaviorChangedText: "read only"
        )
    }

    func testParityImprovesAfterReplay() async {
        let before = canonicalDiagnostics(
            result: .divergentConflict,
            recommendation: "local_first_block_canonical_read",
            remoteShotCount: 1,
            remoteIssueObservationCount: 0
        )
        let beforeReport = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: before)
        let plan = AppState.makeNormalizedBackfillReplayPlan(canonicalDiagnostics: before)

        let execution = await AppState.executeNormalizedBackfillReplayTestOnly(
            plan: plan,
            targetClassification: .localDev
        ) { kind, count in
            AppState.NormalizedBackfillEntityResult(
                kind: kind,
                attemptedCount: count,
                upsertedCount: count,
                skippedCount: 0,
                failedCount: 0,
                message: "upserted_missing_rows"
            )
        }

        let after = canonicalDiagnostics(
            result: .remoteMatchesLocal,
            recommendation: "remote_candidate_after_replay_validation",
            remoteShotCount: 4,
            remoteIssueObservationCount: 2,
            countParity: true
        )
        let afterReport = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: after)
        let validation = AppState.validateNormalizedBackfillReplay(
            before: before,
            after: after,
            execution: execution
        )

        XCTAssertEqual(beforeReport.missingChildCount, 5)
        XCTAssertEqual(afterReport.missingChildCount, 0)
        XCTAssertTrue(execution.allowed)
        XCTAssertEqual(execution.executedEntityCount, 5)
        XCTAssertTrue(validation.parityCompletenessImproved)
        XCTAssertTrue(validation.missingChildCountDecreased)
        XCTAssertTrue(validation.recommendationImproved)
        XCTAssertTrue(validation.remainingCanonicalBlockers.isEmpty)
        XCTAssertTrue(validation.noBehaviorChangedText.contains("does not switch canonical reads"))
    }

    func testDuplicateReplayIsIdempotentAfterParityIsImproved() async {
        let after = canonicalDiagnostics(
            result: .remoteMatchesLocal,
            recommendation: "remote_candidate_after_replay_validation",
            remoteShotCount: 4,
            remoteIssueObservationCount: 2,
            countParity: true
        )
        let plan = AppState.makeNormalizedBackfillReplayPlan(canonicalDiagnostics: after)
        var operationCalled = false

        let secondReplay = await AppState.executeNormalizedBackfillReplayTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { kind, count in
            operationCalled = true
            return AppState.NormalizedBackfillEntityResult(
                kind: kind,
                attemptedCount: count,
                upsertedCount: 0,
                skippedCount: count,
                failedCount: 0,
                message: "duplicate_skipped"
            )
        }

        XCTAssertFalse(plan.eligible)
        XCTAssertEqual(plan.blockedReason, "no_missing_normalized_rows_planned")
        XCTAssertFalse(secondReplay.allowed)
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(secondReplay.executedEntityCount, 0)
    }

    func testRemoteNewerConflictStillBlocksReplayValidation() async {
        let before = canonicalDiagnostics(
            result: .remoteNewerCandidate,
            recommendation: "local_first_block_remote_newer_conflict",
            remoteShotCount: 4,
            remoteIssueObservationCount: 2,
            countParity: true
        )
        let plan = AppState.makeNormalizedBackfillReplayPlan(canonicalDiagnostics: before)
        let execution = await AppState.executeNormalizedBackfillReplayTestOnly(
            plan: plan,
            targetClassification: .localDev
        ) { kind, count in
            AppState.NormalizedBackfillEntityResult(
                kind: kind,
                attemptedCount: count,
                upsertedCount: count,
                skippedCount: 0,
                failedCount: 0,
                message: "should_not_run"
            )
        }

        let validation = AppState.validateNormalizedBackfillReplay(
            before: before,
            after: before,
            execution: execution
        )

        XCTAssertFalse(plan.eligible)
        XCTAssertEqual(plan.remoteNewerConflictCount, 1)
        XCTAssertFalse(execution.allowed)
        XCTAssertEqual(execution.executedEntityCount, 0)
        XCTAssertEqual(validation.remoteNewerConflictCount, 1)
        XCTAssertTrue(validation.remainingCanonicalBlockers.contains("remote_newer_conflict_present"))
    }

    func testProductionReplayBlockedDuringValidation() async {
        let before = canonicalDiagnostics(
            result: .divergentConflict,
            recommendation: "local_first_block_canonical_read",
            remoteShotCount: 0,
            remoteIssueObservationCount: 0
        )
        let plan = AppState.makeNormalizedBackfillReplayPlan(canonicalDiagnostics: before)
        let execution = await AppState.executeNormalizedBackfillReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { kind, count in
            AppState.NormalizedBackfillEntityResult(
                kind: kind,
                attemptedCount: count,
                upsertedCount: count,
                skippedCount: 0,
                failedCount: 0,
                message: "should_not_run"
            )
        }

        XCTAssertFalse(execution.allowed)
        XCTAssertTrue(execution.productionBlocked)
        XCTAssertEqual(execution.blockedReason, "production_backfill_blocked")
        XCTAssertEqual(execution.executedEntityCount, 0)
    }

    func testParentOrgRepairImprovementIsReportedWithoutCanonicalSwitch() async {
        let before = canonicalDiagnostics(
            result: .parentMismatch,
            recommendation: "local_first_block_canonical_read",
            parentOrgConsistent: false,
            remoteShotCount: 0,
            remoteIssueObservationCount: 0
        )
        let plan = AppState.makeNormalizedBackfillReplayPlan(canonicalDiagnostics: before)
        let execution = await AppState.executeNormalizedBackfillReplayTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { kind, count in
            AppState.NormalizedBackfillEntityResult(
                kind: kind,
                attemptedCount: count,
                upsertedCount: count,
                skippedCount: 0,
                failedCount: 0,
                message: "lineage_and_children_replayed"
            )
        }
        let after = canonicalDiagnostics(
            result: .remoteMatchesLocal,
            recommendation: "remote_candidate_after_replay_validation",
            parentOrgConsistent: true,
            remoteShotCount: 4,
            remoteIssueObservationCount: 2,
            countParity: true
        )
        let validation = AppState.validateNormalizedBackfillReplay(
            before: before,
            after: after,
            execution: execution
        )

        XCTAssertTrue(validation.parentOrgConsistencyRepaired)
        XCTAssertTrue(validation.parityCompletenessImproved)
        XCTAssertTrue(validation.missingChildCountDecreased)
        XCTAssertTrue(validation.noBehaviorChangedText.contains("does not switch canonical reads"))
        XCTAssertTrue(validation.noBehaviorChangedText.contains("mutate production data"))
    }
}
