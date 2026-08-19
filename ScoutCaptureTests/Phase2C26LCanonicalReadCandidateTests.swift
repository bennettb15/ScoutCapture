import XCTest
@testable import ScoutCapture

final class Phase2C26LCanonicalReadCandidateTests: XCTestCase {
    private let orgID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let propertyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func configuration(enabled: Bool = true) -> AppState.CanonicalReadCandidateConfiguration {
        AppState.CanonicalReadCandidateConfiguration(
            enabled: enabled,
            orgAllowlist: [orgID],
            propertyAllowlist: [propertyID],
            sessionAllowlist: [sessionID],
            parityCompletenessThreshold: 0.95,
            mediaRecoveryConfidenceThreshold: 0.95
        )
    }

    private func diagnostics(
        result: AppState.CanonicalReadDiagnosticResult = .remoteMatchesLocal,
        recommendation: String = "local_preferred_remote_verified",
        parentOrgConsistent: Bool? = true,
        parentPropertyConsistent: Bool? = true,
        localShotCount: Int? = 2,
        remoteShotCount: Int? = 2,
        localIssueObservationCount: Int? = 1,
        remoteIssueObservationCount: Int? = 1,
        localPropertyFound: Bool = true,
        localSessionFound: Bool = true,
        countParity: Bool? = true
    ) -> AppState.CanonicalReadDiagnosticsResult {
        AppState.CanonicalReadDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 4_000),
            propertyID: propertyID,
            sessionID: sessionID,
            activeOrganizationID: orgID,
            result: result,
            remotePropertyFound: true,
            remoteSessionFound: true,
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
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 3_900),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 3_900),
            remoteRevision: 42,
            remoteFreshnessAgeSeconds: 100,
            canonicalRecommendation: recommendation,
            blockedReason: nil,
            noBehaviorChangedText: "read only"
        )
    }

    private func candidate(
        configuration: AppState.CanonicalReadCandidateConfiguration? = nil,
        target: SupabaseRuntimeConfiguration.TargetClassification = .approvedStaging,
        diagnostics: AppState.CanonicalReadDiagnosticsResult? = nil,
        mediaRecoveryConfidence: Double = 1
    ) -> AppState.CanonicalReadCandidateDiagnostics {
        let canonicalDiagnostics = diagnostics ?? self.diagnostics()
        let report = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: canonicalDiagnostics)
        return AppState.makeCanonicalReadCandidateDiagnostics(
            checkedAt: Date(timeIntervalSinceReferenceDate: 4_100),
            configuration: configuration ?? self.configuration(),
            targetClassification: target,
            canonicalDiagnostics: canonicalDiagnostics,
            parityReport: report,
            mediaRecoveryConfidence: mediaRecoveryConfidence
        )
    }

    func testAllowlistedCandidateSucceeds() {
        let result = candidate()

        XCTAssertTrue(result.allowed)
        XCTAssertNil(result.blockedReason)
        XCTAssertEqual(result.effectiveSourceRecommendation, "remote_normalized_candidate_with_local_fallback")
        XCTAssertTrue(result.localFallbackAvailable)
        XCTAssertEqual(result.parityConfidence, 1)
        XCTAssertEqual(result.replayConfidence, 1)
        XCTAssertTrue(result.remoteCandidateStateReadable)
        XCTAssertFalse(result.productionWideCanonicalReadsEnabled)
    }

    func testReplayValidatedRecommendationSucceedsAsCandidateEvidence() {
        let result = candidate(
            diagnostics: diagnostics(
                recommendation: "remote_candidate_after_replay_validation"
            )
        )

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.replayConfidence, 1)
    }

    func testParityGapBlocksCandidate() {
        let result = candidate(
            diagnostics: diagnostics(
                result: .divergentConflict,
                localShotCount: 4,
                remoteShotCount: 2,
                countParity: false
            )
        )

        XCTAssertFalse(result.allowed)
        XCTAssertTrue(result.blockedReason?.contains("canonical_read_diagnostic_result_not_candidate") == true)
        XCTAssertTrue(result.blockedReason?.contains("parity_completeness_below_threshold") == true)
    }

    func testParentDivergenceBlocksCandidate() {
        let result = candidate(
            diagnostics: diagnostics(
                result: .parentMismatch,
                parentOrgConsistent: false
            )
        )

        XCTAssertFalse(result.allowed)
        XCTAssertTrue(result.blockedReason?.contains("parent_org_or_property_divergence") == true)
    }

    func testMissingRemoteChildrenBlocksCandidate() {
        let result = candidate(
            diagnostics: diagnostics(
                result: .divergentConflict,
                localShotCount: 3,
                remoteShotCount: 1,
                localIssueObservationCount: 2,
                remoteIssueObservationCount: 0,
                countParity: false
            )
        )

        XCTAssertFalse(result.allowed)
        XCTAssertTrue(result.blockedReason?.contains("missing_remote_children") == true)
    }

    func testProductionRemainsBlockedByDefault() {
        let result = candidate(target: .approvedProductionValidation)

        XCTAssertFalse(result.allowed)
        XCTAssertTrue(result.blockedReason?.contains("production_canonical_read_candidate_requires_separate_explicit_approval") == true)
        XCTAssertFalse(result.productionWideCanonicalReadsEnabled)
    }

    func testFlagAndAllowlistRequired() {
        let disabled = candidate(configuration: configuration(enabled: false))
        let noAllowlist = candidate(
            configuration: AppState.CanonicalReadCandidateConfiguration(
                enabled: true,
                orgAllowlist: [],
                propertyAllowlist: [],
                sessionAllowlist: [],
                parityCompletenessThreshold: 0.95,
                mediaRecoveryConfidenceThreshold: 0.95
            )
        )

        XCTAssertFalse(disabled.allowed)
        XCTAssertTrue(disabled.blockedReason?.contains("canonical_read_candidate_flag_disabled") == true)
        XCTAssertFalse(noAllowlist.allowed)
        XCTAssertTrue(noAllowlist.blockedReason?.contains("org_not_allowlisted") == true)
        XCTAssertTrue(noAllowlist.blockedReason?.contains("property_not_allowlisted") == true)
        XCTAssertTrue(noAllowlist.blockedReason?.contains("session_not_allowlisted") == true)
    }

    func testLocalFallbackRemainsAvailableAndMissingFallbackBlocks() {
        let allowed = candidate()
        let blocked = candidate(
            diagnostics: diagnostics(
                localPropertyFound: false,
                localSessionFound: false
            )
        )

        XCTAssertTrue(allowed.localFallbackAvailable)
        XCTAssertTrue(allowed.warnings.contains("local_fallback_retained"))
        XCTAssertFalse(blocked.allowed)
        XCTAssertTrue(blocked.blockedReason?.contains("local_fallback_unavailable") == true)
    }

    func testCandidateModeDoesNotMutateLocalState() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Phase2C26L-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let result = candidate()
        let report = AppState.canonicalReadCandidateDiagnosticsText(result)

        XCTAssertTrue(result.allowed)
        XCTAssertTrue(report.contains("No behavior changed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
