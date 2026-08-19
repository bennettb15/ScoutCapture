import XCTest
@testable import ScoutCapture

final class Phase2C26INormalizedBackfillReplayPrototypeTests: XCTestCase {
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
        localPropertyFound: Bool = true,
        localSessionFound: Bool = true,
        countParity: Bool? = true
    ) -> AppState.CanonicalReadDiagnosticsResult {
        AppState.CanonicalReadDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 3_000),
            propertyID: propertyID,
            sessionID: sessionID,
            activeOrganizationID: orgID,
            result: result,
            remotePropertyFound: remotePropertyFound,
            remoteSessionFound: remoteSessionFound,
            localPropertyFound: localPropertyFound,
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
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 2_900),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 2_900),
            remoteRevision: 22,
            remoteFreshnessAgeSeconds: 100,
            canonicalRecommendation: "local_first_block_canonical_read",
            blockedReason: nil,
            noBehaviorChangedText: "read only"
        )
    }

    func testPlannerDetectsMissingRemoteChildren() {
        let diagnostics = canonicalDiagnostics(
            result: .divergentConflict,
            localShotCount: 4,
            remoteShotCount: 1,
            localIssueObservationCount: 2,
            remoteIssueObservationCount: 0,
            countParity: false
        )
        let plan = AppState.makeNormalizedBackfillReplayPlan(canonicalDiagnostics: diagnostics)

        XCTAssertTrue(plan.eligible)
        XCTAssertFalse(plan.parentLineageRepairNeeded)
        XCTAssertFalse(plan.sessionRowUpsertNeeded)
        XCTAssertEqual(plan.shotRowUpsertsNeeded, 3)
        XCTAssertEqual(plan.observationIssueRowUpsertsNeeded, 2)
        XCTAssertEqual(plan.evidenceSourcePriority.first, "verified_snapshot_payload")
        XCTAssertTrue(plan.canonicalReadsRemainBlocked)
    }

    func testPlannerDetectsParentOrgDivergenceAndPlansLineageRepair() {
        let diagnostics = canonicalDiagnostics(
            result: .parentMismatch,
            parentOrgConsistent: false,
            localShotCount: 3,
            remoteShotCount: 0,
            localIssueObservationCount: 1,
            remoteIssueObservationCount: 0,
            countParity: false
        )
        let plan = AppState.makeNormalizedBackfillReplayPlan(canonicalDiagnostics: diagnostics)

        XCTAssertTrue(plan.eligible)
        XCTAssertTrue(plan.parentLineageRepairNeeded)
        XCTAssertEqual(plan.shotRowUpsertsNeeded, 3)
        XCTAssertEqual(plan.observationIssueRowUpsertsNeeded, 1)
        XCTAssertNil(plan.blockedReason)
    }

    func testPlannerBlocksRemoteNewerConflict() {
        let plan = AppState.makeNormalizedBackfillReplayPlan(
            canonicalDiagnostics: canonicalDiagnostics(result: .remoteNewerCandidate)
        )

        XCTAssertFalse(plan.eligible)
        XCTAssertEqual(plan.remoteNewerConflictCount, 1)
        XCTAssertTrue(plan.blockedReason?.contains("remote_newer_conflict_blocks_backfill") == true)
    }

    func testLocalStagingExecutorUpsertsMissingChildRows() async {
        let plan = AppState.makeNormalizedBackfillReplayPlan(
            canonicalDiagnostics: canonicalDiagnostics(
                result: .divergentConflict,
                localShotCount: 3,
                remoteShotCount: 1,
                localIssueObservationCount: 2,
                remoteIssueObservationCount: 1,
                countParity: false
            )
        )
        var operations: [(AppState.NormalizedBackfillEntityKind, Int)] = []

        let result = await AppState.executeNormalizedBackfillReplayTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { kind, count in
            operations.append((kind, count))
            return AppState.NormalizedBackfillEntityResult(
                kind: kind,
                attemptedCount: count,
                upsertedCount: count,
                skippedCount: 0,
                failedCount: 0,
                message: "ok"
            )
        }

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(operations.map(\.0), [.shot, .observation])
        XCTAssertEqual(result.attemptedEntityCount, 3)
        XCTAssertEqual(result.executedEntityCount, 3)
        XCTAssertEqual(result.failedEntityCount, 0)
    }

    func testDuplicateReplayIsIdempotentWhenPlanHasNoMissingRows() async {
        let plan = AppState.makeNormalizedBackfillReplayPlan(
            canonicalDiagnostics: canonicalDiagnostics(result: .remoteMatchesLocal)
        )
        var operationCalled = false

        let result = await AppState.executeNormalizedBackfillReplayTestOnly(
            plan: plan,
            targetClassification: .localDev
        ) { kind, count in
            operationCalled = true
            return AppState.NormalizedBackfillEntityResult(
                kind: kind,
                attemptedCount: count,
                upsertedCount: 0,
                skippedCount: count,
                failedCount: 0,
                message: "duplicate"
            )
        }

        XCTAssertFalse(plan.eligible)
        XCTAssertFalse(result.allowed)
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.executedEntityCount, 0)
    }

    func testProductionExecutorIsBlocked() async {
        let plan = AppState.makeNormalizedBackfillReplayPlan(
            canonicalDiagnostics: canonicalDiagnostics(
                result: .divergentConflict,
                localShotCount: 2,
                remoteShotCount: 0,
                localIssueObservationCount: 1,
                remoteIssueObservationCount: 0,
                countParity: false
            )
        )

        let result = await AppState.executeNormalizedBackfillReplayTestOnly(
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

        XCTAssertFalse(result.allowed)
        XCTAssertTrue(result.productionBlocked)
        XCTAssertEqual(result.blockedReason, "production_backfill_blocked")
        XCTAssertEqual(result.executedEntityCount, 0)
    }

    func testNoCanonicalReadBehaviorChangesAreDeclared() {
        let plan = AppState.makeNormalizedBackfillReplayPlan(
            canonicalDiagnostics: canonicalDiagnostics(
                result: .divergentConflict,
                localShotCount: 2,
                remoteShotCount: 0,
                countParity: false
            )
        )

        XCTAssertTrue(plan.noBehaviorChangedText.contains("does not switch canonical reads"))
        XCTAssertTrue(plan.noBehaviorChangedText.contains("read-only by default"))
        XCTAssertTrue(plan.noBehaviorChangedText.contains("mutate production data"))
    }
}
