import XCTest
@testable import ScoutCapture

final class Phase2C26MCanonicalCandidatePositivePathTests: XCTestCase {
    private let orgID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let propertyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func configuration(
        allowlisted: Bool = true,
        enabled: Bool = true
    ) -> AppState.CanonicalReadCandidateConfiguration {
        AppState.CanonicalReadCandidateConfiguration(
            enabled: enabled,
            orgAllowlist: allowlisted ? [orgID] : [],
            propertyAllowlist: allowlisted ? [propertyID] : [],
            sessionAllowlist: allowlisted ? [sessionID] : [],
            parityCompletenessThreshold: 0.95,
            mediaRecoveryConfidenceThreshold: 0.95
        )
    }

    private func canonicalDiagnostics(
        result: AppState.CanonicalReadDiagnosticResult,
        recommendation: String,
        localShotCount: Int = 4,
        remoteShotCount: Int,
        localIssueObservationCount: Int = 2,
        remoteIssueObservationCount: Int,
        countParity: Bool
    ) -> AppState.CanonicalReadDiagnosticsResult {
        AppState.CanonicalReadDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 5_000),
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
            parentOrgConsistent: true,
            parentPropertyConsistent: true,
            localShotCount: localShotCount,
            remoteShotCount: remoteShotCount,
            localIssueObservationCount: localIssueObservationCount,
            remoteIssueObservationCount: remoteIssueObservationCount,
            localGuidedCount: 0,
            remoteGuidedCount: nil,
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 4_900),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 4_900),
            remoteRevision: 52,
            remoteFreshnessAgeSeconds: 100,
            canonicalRecommendation: recommendation,
            blockedReason: result == .divergentConflict ? "remote_rows_diverge_from_local_counts_or_status" : nil,
            noBehaviorChangedText: "read only"
        )
    }

    func testRepairedHostedStagingShapeBecomesAllowlistedCandidate() async {
        let before = canonicalDiagnostics(
            result: .divergentConflict,
            recommendation: "local_first_block_canonical_read",
            remoteShotCount: 1,
            remoteIssueObservationCount: 0,
            countParity: false
        )
        let beforeReport = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: before)
        let beforeCandidate = AppState.makeCanonicalReadCandidateDiagnostics(
            configuration: configuration(),
            targetClassification: .approvedStaging,
            canonicalDiagnostics: before,
            parityReport: beforeReport
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
        let replayValidation = AppState.validateNormalizedBackfillReplay(
            before: before,
            after: after,
            execution: execution
        )
        let afterCandidate = AppState.makeCanonicalReadCandidateDiagnostics(
            configuration: configuration(),
            targetClassification: .approvedStaging,
            canonicalDiagnostics: after,
            parityReport: afterReport,
            replayValidation: replayValidation
        )

        XCTAssertFalse(beforeCandidate.allowed)
        XCTAssertTrue(beforeCandidate.blockedReason?.contains("missing_remote_children") == true)
        XCTAssertTrue(execution.allowed)
        XCTAssertEqual(execution.executedEntityCount, 5)
        XCTAssertEqual(after.result, .remoteMatchesLocal)
        XCTAssertEqual(after.canonicalRecommendation, "remote_candidate_after_replay_validation")
        XCTAssertEqual(afterReport.missingChildCount, 0)
        XCTAssertGreaterThanOrEqual(afterReport.parityCompletenessScore, 0.95)
        XCTAssertEqual(after.parentOrgConsistent, true)
        XCTAssertEqual(after.parentPropertyConsistent, true)
        XCTAssertTrue(replayValidation.remainingCanonicalBlockers.isEmpty)
        XCTAssertTrue(afterCandidate.allowed)
        XCTAssertEqual(afterCandidate.effectiveSourceRecommendation, "remote_normalized_candidate_with_local_fallback")
        XCTAssertTrue(afterCandidate.localFallbackAvailable)
        XCTAssertFalse(afterCandidate.productionWideCanonicalReadsEnabled)
        XCTAssertTrue(afterCandidate.noBehaviorChangedText.contains("do not switch global reads"))
    }

    func testNonAllowlistedCandidateStillBlocksAfterParityRepair() {
        let after = canonicalDiagnostics(
            result: .remoteMatchesLocal,
            recommendation: "remote_candidate_after_replay_validation",
            remoteShotCount: 4,
            remoteIssueObservationCount: 2,
            countParity: true
        )
        let report = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: after)
        let candidate = AppState.makeCanonicalReadCandidateDiagnostics(
            configuration: configuration(allowlisted: false),
            targetClassification: .approvedStaging,
            canonicalDiagnostics: after,
            parityReport: report
        )

        XCTAssertFalse(candidate.allowed)
        XCTAssertTrue(candidate.blockedReason?.contains("org_not_allowlisted") == true)
        XCTAssertTrue(candidate.blockedReason?.contains("property_not_allowlisted") == true)
        XCTAssertTrue(candidate.blockedReason?.contains("session_not_allowlisted") == true)
        XCTAssertTrue(candidate.localFallbackAvailable)
    }

    func testProductionCandidateRemainsBlockedEvenWithPositiveParity() {
        let after = canonicalDiagnostics(
            result: .remoteMatchesLocal,
            recommendation: "remote_candidate_after_replay_validation",
            remoteShotCount: 4,
            remoteIssueObservationCount: 2,
            countParity: true
        )
        let report = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: after)
        let candidate = AppState.makeCanonicalReadCandidateDiagnostics(
            configuration: configuration(),
            targetClassification: .approvedProductionValidation,
            canonicalDiagnostics: after,
            parityReport: report
        )

        XCTAssertFalse(candidate.allowed)
        XCTAssertTrue(candidate.blockedReason?.contains("production_canonical_read_candidate_requires_separate_explicit_approval") == true)
        XCTAssertFalse(candidate.productionWideCanonicalReadsEnabled)
    }

    func testPositiveCandidateDoesNotMutateLocalState() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Phase2C26M-\(UUID().uuidString)", isDirectory: true)
        let after = canonicalDiagnostics(
            result: .remoteMatchesLocal,
            recommendation: "remote_candidate_after_replay_validation",
            remoteShotCount: 4,
            remoteIssueObservationCount: 2,
            countParity: true
        )
        let report = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: after)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let candidate = AppState.makeCanonicalReadCandidateDiagnostics(
            configuration: configuration(),
            targetClassification: .approvedStaging,
            canonicalDiagnostics: after,
            parityReport: report
        )

        XCTAssertTrue(candidate.allowed)
        XCTAssertTrue(candidate.localFallbackAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
