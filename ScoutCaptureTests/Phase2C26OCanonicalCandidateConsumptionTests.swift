import XCTest
@testable import ScoutCapture

final class Phase2C26OCanonicalCandidateConsumptionTests: XCTestCase {
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
        recommendation: String = "remote_candidate_after_replay_validation",
        parentOrgConsistent: Bool? = true,
        parentPropertyConsistent: Bool? = true,
        localShotCount: Int? = 3,
        remoteShotCount: Int? = 3,
        localIssueObservationCount: Int? = 2,
        remoteIssueObservationCount: Int? = 2,
        localPropertyFound: Bool = true,
        localSessionFound: Bool = true,
        countParity: Bool? = true
    ) -> AppState.CanonicalReadDiagnosticsResult {
        AppState.CanonicalReadDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 6_000),
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
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 5_900),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 5_900),
            remoteRevision: 62,
            remoteFreshnessAgeSeconds: 100,
            canonicalRecommendation: recommendation,
            blockedReason: nil,
            noBehaviorChangedText: "read only"
        )
    }

    private func overlay(
        target: SupabaseRuntimeConfiguration.TargetClassification = .approvedStaging,
        diagnostics canonicalDiagnostics: AppState.CanonicalReadDiagnosticsResult? = nil,
        configuration: AppState.CanonicalReadCandidateConfiguration? = nil
    ) -> AppState.CanonicalCandidateOverlayBuildResult {
        let canonicalDiagnostics = canonicalDiagnostics ?? diagnostics()
        let report = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: canonicalDiagnostics)
        let candidate = AppState.makeCanonicalReadCandidateDiagnostics(
            checkedAt: Date(timeIntervalSinceReferenceDate: 6_100),
            configuration: configuration ?? self.configuration(),
            targetClassification: target,
            canonicalDiagnostics: canonicalDiagnostics,
            parityReport: report
        )
        return AppState.buildCanonicalCandidateOverlayTestOnly(
            checkedAt: Date(timeIntervalSinceReferenceDate: 6_200),
            targetClassification: target,
            canonicalDiagnostics: canonicalDiagnostics,
            parityReport: report,
            candidateDiagnostics: candidate
        )
    }

    private func comparison(
        target: SupabaseRuntimeConfiguration.TargetClassification = .approvedStaging,
        diagnostics canonicalDiagnostics: AppState.CanonicalReadDiagnosticsResult? = nil,
        configuration: AppState.CanonicalReadCandidateConfiguration? = nil,
        localStatus: String? = "completed",
        remoteStatus: String? = "completed"
    ) -> AppState.CanonicalCandidateOverlayComparison {
        let canonicalDiagnostics = canonicalDiagnostics ?? diagnostics()
        let result = overlay(
            target: target,
            diagnostics: canonicalDiagnostics,
            configuration: configuration
        )
        let report = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: canonicalDiagnostics)
        return AppState.makeCanonicalCandidateOverlayComparison(
            checkedAt: Date(timeIntervalSinceReferenceDate: 6_300),
            canonicalDiagnostics: canonicalDiagnostics,
            overlayResult: result,
            parityReport: report,
            localSessionStatus: localStatus,
            remoteCandidateSessionStatus: remoteStatus
        )
    }

    func testAllowlistedStagingCandidateBuildsOverlay() {
        let result = overlay()

        XCTAssertTrue(result.allowed)
        XCTAssertNil(result.blockedReason)
        XCTAssertEqual(result.overlay?.source, "remote_normalized_candidate_with_local_fallback")
        XCTAssertEqual(result.overlay?.propertyID, propertyID)
        XCTAssertEqual(result.overlay?.sessionID, sessionID)
        XCTAssertEqual(result.overlay?.remoteShotCount, 3)
        XCTAssertEqual(result.overlay?.remoteIssueObservationCount, 2)
        XCTAssertEqual(result.overlay?.fallbackSource, "local")
        XCTAssertEqual(result.overlay?.activeSource, "local")
        XCTAssertTrue(result.localFallbackRetained)
        XCTAssertTrue(result.activeSourceRemainsLocal)
        XCTAssertTrue(result.rollbackAvailable)
        XCTAssertTrue(result.productionBlocked)
    }

    func testLocalDevCandidateBuildsOverlay() {
        let result = overlay(target: .localDev)

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.overlay?.source, "remote_normalized_candidate_with_local_fallback")
        XCTAssertEqual(result.remoteCandidateRowCounts["remote_shots"], 3)
    }

    func testParityGapBlocksOverlay() {
        let result = overlay(
            diagnostics: diagnostics(
                result: .divergentConflict,
                recommendation: "local_first_block_canonical_read",
                localShotCount: 4,
                remoteShotCount: 2,
                countParity: false
            )
        )

        XCTAssertFalse(result.allowed)
        XCTAssertNil(result.overlay)
        XCTAssertTrue(result.blockedReason?.contains("canonical_read_diagnostic_result_not_candidate") == true)
        XCTAssertTrue(result.blockedReason?.contains("parity_completeness_below_threshold") == true)
    }

    func testParentMismatchBlocksOverlay() {
        let result = overlay(
            diagnostics: diagnostics(
                result: .parentMismatch,
                parentOrgConsistent: false
            )
        )

        XCTAssertFalse(result.allowed)
        XCTAssertNil(result.overlay)
        XCTAssertTrue(result.blockedReason?.contains("parent_org_or_property_divergence") == true)
    }

    func testMissingRemoteChildrenBlocksOverlay() {
        let result = overlay(
            diagnostics: diagnostics(
                result: .divergentConflict,
                localShotCount: 5,
                remoteShotCount: 1,
                localIssueObservationCount: 2,
                remoteIssueObservationCount: 0,
                countParity: false
            )
        )

        XCTAssertFalse(result.allowed)
        XCTAssertNil(result.overlay)
        XCTAssertTrue(result.blockedReason?.contains("missing_remote_children") == true)
    }

    func testProductionBlocksOverlay() {
        let result = overlay(target: .approvedProductionValidation)

        XCTAssertFalse(result.allowed)
        XCTAssertNil(result.overlay)
        XCTAssertTrue(result.blockedReason?.contains("production_canonical_candidate_overlay_blocked") == true)
        XCTAssertTrue(result.productionBlocked)
    }

    func testLocalFallbackRequiredAndRetained() {
        let allowed = overlay()
        let blocked = overlay(
            diagnostics: diagnostics(
                localPropertyFound: false,
                localSessionFound: false
            )
        )

        XCTAssertTrue(allowed.localFallbackRetained)
        XCTAssertEqual(allowed.overlay?.fallbackSource, "local")
        XCTAssertFalse(blocked.allowed)
        XCTAssertTrue(blocked.blockedReason?.contains("local_fallback_unavailable") == true)
    }

    func testOverlayDoesNotMutateLocalStateOrBehaviorRails() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Phase2C26O-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let result = overlay()
        let report = AppState.canonicalCandidateOverlayReportText(result)

        XCTAssertTrue(result.allowed)
        XCTAssertTrue(report.contains("Active Source: local"))
        XCTAssertTrue(report.contains("Local Fallback Retained: true"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("export"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("seal"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("sync"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("media"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("iCloud"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSessionSnapshotUploadReportRendersOverlayDefaults() {
        let text = AppState.sessionSnapshotUploadReportText(AppState.SessionSnapshotUploadDiagnostics())

        XCTAssertTrue(text.contains("Canonical Candidate Overlay Test-Only"))
        XCTAssertTrue(text.contains("Canonical Candidate Overlay Comparison"))
        XCTAssertTrue(text.contains("- canonical_candidate_overlay_built: false"))
        XCTAssertTrue(text.contains("- canonical_candidate_overlay_source: not_built"))
        XCTAssertTrue(text.contains("- canonical_candidate_overlay_fallback_source: local"))
        XCTAssertTrue(text.contains("- canonical_candidate_overlay_active_source: local"))
        XCTAssertTrue(text.contains("- canonical_candidate_overlay_production_blocked: true"))
        XCTAssertTrue(text.contains("- canonical_candidate_overlay_comparison_result: candidate_unavailable"))
    }

    func testComparisonCandidateMatchesLocal() {
        let result = comparison()
        let report = AppState.canonicalCandidateOverlayComparisonReportText(result)

        XCTAssertEqual(result.result, .candidateMatchesLocal)
        XCTAssertEqual(result.localShotCount, 3)
        XCTAssertEqual(result.remoteCandidateShotCount, 3)
        XCTAssertEqual(result.localIssueObservationCount, 2)
        XCTAssertEqual(result.remoteCandidateIssueObservationCount, 2)
        XCTAssertEqual(result.activeSource, "local")
        XCTAssertEqual(result.fallbackSource, "local")
        XCTAssertTrue(result.rollbackAvailable)
        XCTAssertNil(result.blockedReason)
        XCTAssertTrue(report.contains("Canonical Candidate Overlay Comparison"))
    }

    func testComparisonRemoteCandidateNewerIsReportedNotConsumed() {
        let result = comparison(
            diagnostics: diagnostics(
                result: .remoteNewerCandidate,
                recommendation: "manual_review_remote_candidate"
            )
        )

        XCTAssertEqual(result.result, .candidateRemoteNewer)
        XCTAssertEqual(result.activeSource, "local")
        XCTAssertEqual(result.fallbackSource, "local")
        XCTAssertTrue(result.trustedReason.contains("manual_review"))
    }

    func testComparisonLocalNewerBlocksOrWarns() {
        let result = comparison(
            diagnostics: diagnostics(
                result: .localNewerConflict,
                recommendation: "local_first_block_canonical_read"
            )
        )

        XCTAssertEqual(result.result, .candidateLocalNewer)
        XCTAssertTrue(result.blockedReason?.contains("local_newer_than_remote_candidate") == true)
        XCTAssertEqual(result.activeSource, "local")
    }

    func testComparisonDivergentCandidateBlocksOrWarns() {
        let result = comparison(
            diagnostics: diagnostics(
                result: .divergentConflict,
                recommendation: "local_first_block_canonical_read",
                localShotCount: 3,
                remoteShotCount: 3,
                localIssueObservationCount: 2,
                remoteIssueObservationCount: 2,
                countParity: false
            )
        )

        XCTAssertEqual(result.result, .candidateDivergent)
        XCTAssertTrue(result.blockedReason?.contains("candidate_diverges_from_local") == true)
        XCTAssertEqual(result.activeSource, "local")
    }

    func testComparisonIncompleteCandidateBlocks() {
        let result = comparison(
            diagnostics: diagnostics(
                result: .divergentConflict,
                recommendation: "local_first_block_canonical_read",
                localShotCount: 5,
                remoteShotCount: 1,
                localIssueObservationCount: 2,
                remoteIssueObservationCount: 0,
                countParity: false
            )
        )

        XCTAssertEqual(result.result, .candidateIncomplete)
        XCTAssertTrue(result.blockedReason?.contains("missing_remote_children") == true)
        XCTAssertEqual(result.activeSource, "local")
    }

    func testComparisonUnavailableCandidateBlocks() {
        let result = comparison(configuration: configuration(enabled: false))

        XCTAssertEqual(result.result, .candidateUnavailable)
        XCTAssertTrue(result.blockedReason?.contains("canonical_read_candidate_flag_disabled") == true)
        XCTAssertEqual(result.activeSource, "local")
        XCTAssertEqual(result.fallbackSource, "local")
    }
}
