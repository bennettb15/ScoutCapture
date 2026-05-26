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

    private func activationDiagnostics(
        target: SupabaseRuntimeConfiguration.TargetClassification = .approvedStaging,
        diagnostics canonicalDiagnostics: AppState.CanonicalReadDiagnosticsResult? = nil,
        configuration: AppState.CanonicalReadCandidateConfiguration? = nil,
        remoteNewerConflictCount: Int = 0
    ) -> AppState.SessionSnapshotUploadDiagnostics {
        let canonicalDiagnostics = canonicalDiagnostics ?? diagnostics()
        let configuration = configuration ?? self.configuration()
        let parityReport = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: canonicalDiagnostics)
        let candidate = AppState.makeCanonicalReadCandidateDiagnostics(
            checkedAt: Date(timeIntervalSinceReferenceDate: 6_100),
            configuration: configuration,
            targetClassification: target,
            canonicalDiagnostics: canonicalDiagnostics,
            parityReport: parityReport
        )
        let overlayResult = AppState.buildCanonicalCandidateOverlayTestOnly(
            checkedAt: Date(timeIntervalSinceReferenceDate: 6_200),
            targetClassification: target,
            canonicalDiagnostics: canonicalDiagnostics,
            parityReport: parityReport,
            candidateDiagnostics: candidate
        )
        let comparison = AppState.makeCanonicalCandidateOverlayComparison(
            checkedAt: Date(timeIntervalSinceReferenceDate: 6_300),
            canonicalDiagnostics: canonicalDiagnostics,
            overlayResult: overlayResult,
            parityReport: parityReport
        )

        var upload = AppState.SessionSnapshotUploadDiagnostics()
        upload.lastCanonicalReadDiagnosticsResult = canonicalDiagnostics.result.rawValue
        upload.lastCanonicalReadDiagnosticsPropertyID = canonicalDiagnostics.propertyID
        upload.lastCanonicalReadDiagnosticsSessionID = canonicalDiagnostics.sessionID
        upload.lastCanonicalReadDiagnosticsParentOrgConsistent = canonicalDiagnostics.parentOrgConsistent
        upload.lastCanonicalReadDiagnosticsParentPropertyConsistent = canonicalDiagnostics.parentPropertyConsistent
        upload.lastNormalizedParityGapTaxonomy = parityReport.taxonomy.map(\.rawValue)
        upload.lastMissingChildCount = parityReport.missingChildCount
        upload.lastNormalizedBackfillRemoteNewerConflictCount = remoteNewerConflictCount
        upload.lastCanonicalReadCandidateFlagEnabled = configuration.enabled
        upload.lastCanonicalReadCandidateOrgAllowlisted = configuration.orgAllowlist.contains(orgID)
        upload.lastCanonicalReadCandidatePropertyAllowlisted = configuration.propertyAllowlist.contains(propertyID)
        upload.lastCanonicalReadCandidateSessionAllowlisted = configuration.sessionAllowlist.contains(sessionID)
        upload.lastCanonicalReadCandidateAllowed = candidate.allowed
        upload.lastCanonicalReadCandidateBlockedReason = candidate.blockedReason ?? "none"
        upload.lastCanonicalReadCandidateLocalFallbackAvailable = candidate.localFallbackAvailable
        upload.lastCanonicalReadCandidateParityConfidence = candidate.parityConfidence
        upload.lastCanonicalReadCandidateReplayConfidence = candidate.replayConfidence
        upload.lastCanonicalReadCandidateMediaRecoveryConfidence = candidate.mediaRecoveryConfidence
        upload.lastCanonicalCandidateOverlayBuilt = overlayResult.overlay != nil
        upload.lastCanonicalCandidateOverlayAllowed = overlayResult.allowed
        upload.lastCanonicalCandidateOverlayBlockedReason = overlayResult.blockedReason ?? "none"
        upload.lastCanonicalCandidateOverlayPropertyID = overlayResult.overlay?.propertyID
        upload.lastCanonicalCandidateOverlaySessionID = overlayResult.overlay?.sessionID
        upload.lastCanonicalCandidateOverlayRollbackAvailable = overlayResult.rollbackAvailable
        upload.lastCanonicalCandidateOverlayComparisonResult = comparison.result.rawValue
        return upload
    }

    private func activation(
        target: SupabaseRuntimeConfiguration.TargetClassification = .approvedStaging,
        diagnostics canonicalDiagnostics: AppState.CanonicalReadDiagnosticsResult? = nil,
        configuration: AppState.CanonicalReadCandidateConfiguration? = nil,
        remoteNewerConflictCount: Int = 0
    ) -> AppState.CanonicalCandidateActivationResult {
        AppState.makeCanonicalCandidateActivationResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 6_400),
            targetClassification: target,
            diagnostics: activationDiagnostics(
                target: target,
                diagnostics: canonicalDiagnostics,
                configuration: configuration,
                remoteNewerConflictCount: remoteNewerConflictCount
            )
        )
    }

    private func rolloutReadinessDiagnostics(
        target: SupabaseRuntimeConfiguration.TargetClassification = .approvedStaging,
        diagnostics canonicalDiagnostics: AppState.CanonicalReadDiagnosticsResult? = nil,
        configuration: AppState.CanonicalReadCandidateConfiguration? = nil,
        rollbackAvailable: Bool = true,
        productionWideEnabled: Bool = false
    ) -> AppState.SessionSnapshotUploadDiagnostics {
        let canonicalDiagnostics = canonicalDiagnostics ?? diagnostics()
        let configuration = configuration ?? self.configuration()
        let activationResult = activation(
            target: target,
            diagnostics: canonicalDiagnostics,
            configuration: configuration
        )
        let parityReport = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: canonicalDiagnostics)
        var upload = activationDiagnostics(
            target: target,
            diagnostics: canonicalDiagnostics,
            configuration: configuration
        )
        upload.lastCanonicalReadDiagnosticsRecommendation = canonicalDiagnostics.canonicalRecommendation
        upload.lastNormalizedParityCompleteness = parityReport.normalizedParityCompleteness
        upload.lastParityCompletenessScore = parityReport.parityCompletenessScore
        upload.lastCanonicalReadCandidateProductionWideEnabled = productionWideEnabled
        upload.lastCanonicalCandidateOverlayProductionBlocked = true
        upload.lastCanonicalCandidateActivationAllowed = activationResult.allowed
        upload.lastCanonicalCandidateActivationBlockedReason = activationResult.blockedReason ?? "none"
        upload.lastCanonicalCandidateActivationActiveSource = activationResult.activeSource.rawValue
        upload.lastCanonicalCandidateActivationRollbackSource = activationResult.rollbackSource.rawValue
        upload.lastCanonicalCandidateActivationScope = activationResult.activationScope
        upload.lastCanonicalCandidateActivationRollbackAvailable = rollbackAvailable
        upload.lastCanonicalCandidateOverlayRollbackAvailable = rollbackAvailable
        upload.lastCanonicalCandidateActivationProductionBlocked = true
        upload.lastCanonicalReadCandidateEffectiveSourceRecommendation = "remote_normalized_candidate_with_local_fallback"
        upload.lastCanonicalCandidateOverlaySource = "remote_normalized_candidate_with_local_fallback"
        upload.lastCanonicalCandidateOverlayActiveSource = "local"
        upload.lastCanonicalCandidateOverlayFallbackSource = "local"
        return upload
    }

    private func cohortPolicy(
        requestedStage: AppState.ProductionCohortRolloutStage = .diagnosticsOnly,
        approvalState: AppState.ProductionCohortOperatorApprovalState = .notRequested,
        productionWideEnabled: Bool = false
    ) -> AppState.ProductionCohortControlPlanePolicy {
        AppState.ProductionCohortControlPlanePolicy(
            requestedStage: requestedStage,
            operatorApprovalState: approvalState,
            productionWideCanonicalReadsEnabled: productionWideEnabled,
            parityConfidenceThreshold: 0.95,
            replayConfidenceThreshold: 0.95
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
        XCTAssertTrue(text.contains("Canonical Candidate Activation Test-Only"))
        XCTAssertTrue(text.contains("- canonical_candidate_overlay_built: false"))
        XCTAssertTrue(text.contains("- canonical_candidate_overlay_source: not_built"))
        XCTAssertTrue(text.contains("- canonical_candidate_overlay_fallback_source: local"))
        XCTAssertTrue(text.contains("- canonical_candidate_overlay_active_source: local"))
        XCTAssertTrue(text.contains("- canonical_candidate_overlay_production_blocked: true"))
        XCTAssertTrue(text.contains("- canonical_candidate_overlay_comparison_result: candidate_unavailable"))
        XCTAssertTrue(text.contains("- canonical_candidate_activation_active_source: local"))
        XCTAssertTrue(text.contains("- canonical_candidate_activation_scope: selected_session_only"))
        XCTAssertTrue(text.contains("- canonical_candidate_activation_production_blocked: true"))
    }

    func testCanonicalReadRolloutReportSummarizesOperatorFields() {
        var upload = activationDiagnostics()
        upload.lastCanonicalReadDiagnosticsRecommendation = "remote_candidate_after_replay_validation"
        upload.lastNormalizedParityCompleteness = "complete"
        upload.lastParityCompletenessScore = 1
        upload.lastCanonicalCandidateActivationAllowed = true
        upload.lastCanonicalCandidateActivationActiveSource = "canonical_candidate"
        upload.lastCanonicalCandidateActivationBlockedReason = "none"
        upload.lastCanonicalCandidateActivationRollbackAvailable = true
        upload.lastCanonicalCandidateActivationProductionBlocked = true

        let text = AppState.canonicalReadRolloutReportText(upload)

        XCTAssertTrue(text.contains("ScoutCapture Local Health - Canonical Read Rollout Report"))
        XCTAssertTrue(text.contains("Summary"))
        XCTAssertTrue(text.contains("- canonical_read_result: remote_matches_local"))
        XCTAssertTrue(text.contains("- recommendation: remote_candidate_after_replay_validation"))
        XCTAssertTrue(text.contains("- parity_completeness_score: 1.00"))
        XCTAssertTrue(text.contains("- missing_child_count: 0"))
        XCTAssertTrue(text.contains("- candidate_allowed: true"))
        XCTAssertTrue(text.contains("- overlay_built: true"))
        XCTAssertTrue(text.contains("- overlay_comparison_result: candidate_matches_local"))
        XCTAssertTrue(text.contains("- activation_allowed: true"))
        XCTAssertTrue(text.contains("- active_source: canonical_candidate"))
        XCTAssertTrue(text.contains("- rollback_available: true"))
        XCTAssertTrue(text.contains("- fallback_available: true"))
        XCTAssertTrue(text.contains("- production_activation_blocked: true"))
        XCTAssertTrue(text.contains("Read Diagnostics"))
        XCTAssertTrue(text.contains("Parity / Repair"))
        XCTAssertTrue(text.contains("Candidate"))
        XCTAssertTrue(text.contains("Overlay"))
        XCTAssertTrue(text.contains("Comparison"))
        XCTAssertTrue(text.contains("Activation / Rollback"))
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

    func testActivationSucceedsForAllowlistedMatchingCandidate() {
        let result = activation()

        XCTAssertTrue(result.allowed)
        XCTAssertNil(result.blockedReason)
        XCTAssertEqual(result.activeSource, .canonicalCandidate)
        XCTAssertEqual(result.rollbackSource, .local)
        XCTAssertEqual(result.activationScope, "selected_session_only")
        XCTAssertEqual(result.propertyID, propertyID)
        XCTAssertEqual(result.sessionID, sessionID)
        XCTAssertTrue(result.rollbackAvailable)
        XCTAssertTrue(result.productionBlocked)
    }

    func testActivationBlocksWithoutOverlay() {
        var upload = activationDiagnostics()
        upload.lastCanonicalCandidateOverlayBuilt = false
        upload.lastCanonicalCandidateOverlayAllowed = false
        upload.lastCanonicalCandidateOverlayBlockedReason = "canonical_candidate_overlay_not_built"

        let result = AppState.makeCanonicalCandidateActivationResult(
            targetClassification: .approvedStaging,
            diagnostics: upload
        )

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.activeSource, .local)
        XCTAssertTrue(result.blockedReason?.contains("canonical_candidate_overlay_not_built") == true)
    }

    func testActivationBlocksParityGap() {
        let result = activation(
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

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.activeSource, .local)
        XCTAssertTrue(result.blockedReason?.contains("missing_remote_children") == true)
    }

    func testActivationBlocksParentMismatch() {
        let result = activation(
            diagnostics: diagnostics(
                result: .parentMismatch,
                parentOrgConsistent: false
            )
        )

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.activeSource, .local)
        XCTAssertTrue(result.blockedReason?.contains("parent_org_or_property_divergence") == true)
    }

    func testActivationBlocksProduction() {
        let result = activation(target: .approvedProductionValidation)

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.activeSource, .local)
        XCTAssertTrue(result.blockedReason?.contains("production_canonical_candidate_activation_blocked") == true)
        XCTAssertTrue(result.productionBlocked)
    }

    func testActivationBlocksRemoteNewerConflict() {
        let result = activation(remoteNewerConflictCount: 1)

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.activeSource, .local)
        XCTAssertTrue(result.blockedReason?.contains("remote_newer_conflict") == true)
    }

    func testRollbackReturnsActiveSourceToLocal() {
        var upload = activationDiagnostics()
        upload.lastCanonicalCandidateActivationPropertyID = propertyID
        upload.lastCanonicalCandidateActivationSessionID = sessionID

        let result = AppState.makeCanonicalCandidateRollbackResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 6_500),
            diagnostics: upload
        )

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.activeSource, .local)
        XCTAssertEqual(result.rollbackSource, .local)
        XCTAssertEqual(result.activationScope, "selected_session_only")
        XCTAssertEqual(result.propertyID, propertyID)
        XCTAssertEqual(result.sessionID, sessionID)
        XCTAssertTrue(result.rollbackAvailable)
    }

    func testActivationDoesNotMutateLocalStateOrBehaviorRails() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Phase2C26R-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let result = activation()
        let report = AppState.canonicalCandidateActivationReportText(result)

        XCTAssertTrue(result.allowed)
        XCTAssertTrue(report.contains("- active_source: canonical_candidate"))
        XCTAssertTrue(report.contains("- rollback_source: local"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("global reads"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("local state"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("remote state"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("export"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("seal"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("sync"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("media"))
        XCTAssertTrue(result.noBehaviorChangedText.contains("iCloud"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCanonicalRolloutReadinessDefaultStateIsNotReady() {
        let readiness = AppState.makeCanonicalRolloutReadinessDiagnostics(
            AppState.SessionSnapshotUploadDiagnostics()
        )

        XCTAssertEqual(readiness.state, .notReady)
        XCTAssertTrue(readiness.blockers.contains("canonical_diagnostics_not_candidate"))
        XCTAssertEqual(readiness.nextRecommendedAction, "run_canonical_read_diagnostics")
        XCTAssertFalse(readiness.checklistPassed)
    }

    func testCanonicalRolloutReadinessBlockedParityIsBlocked() {
        let upload = rolloutReadinessDiagnostics(
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

        let readiness = AppState.makeCanonicalRolloutReadinessDiagnostics(upload)

        XCTAssertEqual(readiness.state, .blocked)
        XCTAssertTrue(readiness.blockers.contains("missing_remote_children"))
        XCTAssertTrue(readiness.blockers.contains("parity_completeness_below_threshold"))
        XCTAssertEqual(readiness.nextRecommendedAction, "resolve_rollout_blockers_before_candidate_consumption")
    }

    func testCanonicalRolloutReadinessPositiveCandidateReachesSingleSessionReadiness() {
        let upload = rolloutReadinessDiagnostics()

        let readiness = AppState.makeCanonicalRolloutReadinessDiagnostics(upload)

        XCTAssertEqual(readiness.state, .readyForSingleSessionActivation)
        XCTAssertTrue(readiness.blockers.isEmpty)
        XCTAssertEqual(readiness.nextRecommendedAction, "manual_single_session_activation_validation")
        XCTAssertTrue(readiness.checklistPassed)
    }

    func testCanonicalRolloutReadinessMissingRollbackBlocksReadiness() {
        let upload = rolloutReadinessDiagnostics(rollbackAvailable: false)

        let readiness = AppState.makeCanonicalRolloutReadinessDiagnostics(upload)

        XCTAssertEqual(readiness.state, .blocked)
        XCTAssertTrue(readiness.blockers.contains("rollback_unavailable"))
    }

    func testCanonicalRolloutReadinessProductionWideEnabledBlocksReadiness() {
        let upload = rolloutReadinessDiagnostics(productionWideEnabled: true)

        let readiness = AppState.makeCanonicalRolloutReadinessDiagnostics(upload)

        XCTAssertEqual(readiness.state, .blocked)
        XCTAssertTrue(readiness.blockers.contains("production_wide_canonical_reads_not_blocked"))
    }

    func testCanonicalRolloutReportIncludesReadinessBlockersAndNextAction() {
        let upload = rolloutReadinessDiagnostics(
            diagnostics: diagnostics(
                result: .parentMismatch,
                recommendation: "local_first_block_canonical_read",
                parentOrgConsistent: false
            )
        )

        let text = AppState.canonicalReadRolloutReportText(upload)

        XCTAssertTrue(text.contains("- readiness_state: blocked"))
        XCTAssertTrue(text.contains("parent_org_or_property_divergence"))
        XCTAssertTrue(text.contains("- next_recommended_action: resolve_rollout_blockers_before_candidate_consumption"))
        XCTAssertTrue(text.contains("Canonical Rollout Readiness"))
        XCTAssertTrue(text.contains("Rollout Checklist"))
        XCTAssertTrue(text.contains("No behavior changed"))
    }

    func testProductionAllowlistReadinessDefaultProductionBlocked() {
        let readiness = AppState.makeProductionAllowlistReadinessDiagnostics(
            AppState.SessionSnapshotUploadDiagnostics()
        )

        XCTAssertEqual(readiness.state, .productionBlocked)
        XCTAssertTrue(readiness.blockers.contains("canonical_diagnostics_not_candidate"))
        XCTAssertTrue(readiness.blockers.contains("parity_confidence_below_threshold"))
        XCTAssertTrue(readiness.operatorWorkflowDiagnostics.contains(.pendingParityValidation))
        XCTAssertTrue(readiness.operatorWorkflowDiagnostics.contains(.blockedByUnresolvedConflicts))
        XCTAssertTrue(readiness.operatorApprovalRequired)
    }

    func testProductionAllowlistReadinessUnresolvedBlockersBlockProduction() {
        let upload = rolloutReadinessDiagnostics(
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

        let readiness = AppState.makeProductionAllowlistReadinessDiagnostics(upload)

        XCTAssertEqual(readiness.state, .productionBlocked)
        XCTAssertTrue(readiness.blockers.contains("unresolved_rollout_blockers"))
        XCTAssertTrue(readiness.operatorWorkflowDiagnostics.contains(.blockedByUnresolvedConflicts))
    }

    func testProductionAllowlistReadinessMissingRollbackBlocksReadiness() {
        let upload = rolloutReadinessDiagnostics(rollbackAvailable: false)

        let readiness = AppState.makeProductionAllowlistReadinessDiagnostics(upload)

        XCTAssertEqual(readiness.state, .productionBlocked)
        XCTAssertTrue(readiness.blockers.contains("rollback_validation_required"))
        XCTAssertTrue(readiness.operatorWorkflowDiagnostics.contains(.pendingRollbackValidation))
        XCTAssertFalse(readiness.rollbackValidated)
    }

    func testProductionAllowlistReadinessPositiveCandidateReachesPendingOperatorApproval() {
        let upload = rolloutReadinessDiagnostics()

        let readiness = AppState.makeProductionAllowlistReadinessDiagnostics(upload)

        XCTAssertEqual(readiness.state, .productionAllowlistPendingOperatorApproval)
        XCTAssertTrue(readiness.blockers.isEmpty)
        XCTAssertTrue(readiness.operatorWorkflowDiagnostics.contains(.pendingOperatorReview))
        XCTAssertTrue(readiness.operatorApprovalRequired)
        XCTAssertTrue(readiness.rollbackValidated)
        XCTAssertEqual(readiness.productionCohortSizeRecommendation, "single_org_property_session")
    }

    func testProductionAllowlistReadinessProductionWideEnablementStillBlocked() {
        let upload = rolloutReadinessDiagnostics(productionWideEnabled: true)

        let readiness = AppState.makeProductionAllowlistReadinessDiagnostics(upload)

        XCTAssertEqual(readiness.state, .productionBlocked)
        XCTAssertTrue(readiness.blockers.contains("production_wide_enablement_blocked"))
        XCTAssertTrue(readiness.blockers.contains("production_wide_canonical_reads_not_allowed"))
    }

    func testCanonicalRolloutReportIncludesLimitedProductionReadinessSectionAndRows() {
        let upload = rolloutReadinessDiagnostics()

        let text = AppState.canonicalReadRolloutReportText(upload)

        XCTAssertTrue(text.contains("Limited Production Rollout Readiness"))
        XCTAssertTrue(text.contains("- production_readiness_state: production_allowlist_pending_operator_approval"))
        XCTAssertTrue(text.contains("- operator_workflow_diagnostics: pending_operator_review"))
        XCTAssertTrue(text.contains("- operator approval required: true"))
        XCTAssertTrue(text.contains("- rollback validated: true"))
        XCTAssertTrue(text.contains("- production cohort size recommendation: single_org_property_session"))
        XCTAssertTrue(text.contains("does not enable production canonical reads"))
    }

    func testProductionCohortControlPlaneDefaultCohortBlocked() {
        let diagnostics = AppState.makeProductionCohortControlPlaneDiagnostics(
            AppState.SessionSnapshotUploadDiagnostics()
        )

        XCTAssertEqual(diagnostics.cohort.rolloutStage, .blocked)
        XCTAssertEqual(diagnostics.cohort.activationEligibility, .blocked)
        XCTAssertTrue(diagnostics.blockers.contains("org_id_required"))
        XCTAssertTrue(diagnostics.blockers.contains("property_id_required"))
        XCTAssertTrue(diagnostics.eligibility.productionWideDisabled)
    }

    func testProductionCohortControlPlaneDiagnosticsOnlyCohortAllowedAsDiagnostics() {
        let upload = rolloutReadinessDiagnostics()

        let diagnostics = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID
        )

        XCTAssertEqual(diagnostics.cohort.orgID, orgID)
        XCTAssertEqual(diagnostics.cohort.propertyID, propertyID)
        XCTAssertEqual(diagnostics.cohort.sessionID, sessionID)
        XCTAssertEqual(diagnostics.cohort.rolloutStage, .diagnosticsOnly)
        XCTAssertEqual(diagnostics.cohort.activationEligibility, .diagnosticsOnly)
        XCTAssertTrue(diagnostics.eligibility.productionWideDisabled)
    }

    func testProductionCohortControlPlaneMissingAllowlistBlocksActivation() {
        let upload = rolloutReadinessDiagnostics(
            configuration: AppState.CanonicalReadCandidateConfiguration(
                enabled: true,
                orgAllowlist: [],
                propertyAllowlist: [],
                sessionAllowlist: [],
                parityCompletenessThreshold: 0.95,
                mediaRecoveryConfidenceThreshold: 0.95
            )
        )

        let diagnostics = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            )
        )

        XCTAssertEqual(diagnostics.cohort.rolloutStage, .blocked)
        XCTAssertTrue(diagnostics.blockers.contains("allowlist_incomplete"))
        XCTAssertFalse(diagnostics.eligibility.allowlistComplete)
    }

    func testProductionCohortControlPlaneMissingRollbackValidationBlocksActivation() {
        let upload = rolloutReadinessDiagnostics(rollbackAvailable: false)

        let diagnostics = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            )
        )

        XCTAssertEqual(diagnostics.cohort.rolloutStage, .blocked)
        XCTAssertEqual(diagnostics.cohort.rollbackValidationState, .notValidated)
        XCTAssertTrue(diagnostics.blockers.contains("activation_rollback_not_verified"))
    }

    func testProductionCohortControlPlaneOperatorRejectedBlocksActivation() {
        let upload = rolloutReadinessDiagnostics()

        let diagnostics = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .rejected
            )
        )

        XCTAssertEqual(diagnostics.cohort.rolloutStage, .blocked)
        XCTAssertEqual(diagnostics.cohort.operatorApprovalState, .rejected)
        XCTAssertTrue(diagnostics.blockers.contains("operator_rejected"))
    }

    func testProductionCohortControlPlaneApprovedAllChecksReachesSingleSessionReadinessOnly() {
        let upload = rolloutReadinessDiagnostics()

        let diagnostics = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            )
        )

        XCTAssertEqual(diagnostics.cohort.rolloutStage, .singleSessionActivation)
        XCTAssertEqual(diagnostics.cohort.activationEligibility, .singleSessionReadinessOnly)
        XCTAssertEqual(diagnostics.cohort.rollbackValidationState, .verified)
        XCTAssertEqual(diagnostics.cohort.parityValidationState, .verified)
        XCTAssertTrue(diagnostics.blockers.isEmpty)
        XCTAssertTrue(diagnostics.noBehaviorChangedText.contains("does not enable production canonical reads"))
        XCTAssertTrue(diagnostics.noBehaviorChangedText.contains("activate production candidates"))
    }

    func testProductionCohortControlPlaneProductionWideEnabledRemainsBlocked() {
        let upload = rolloutReadinessDiagnostics(productionWideEnabled: true)

        let diagnostics = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved,
                productionWideEnabled: true
            )
        )

        XCTAssertEqual(diagnostics.cohort.rolloutStage, .blocked)
        XCTAssertFalse(diagnostics.eligibility.productionWideDisabled)
        XCTAssertTrue(diagnostics.blockers.contains("production_wide_canonical_reads_not_disabled"))
    }

    func testCanonicalRolloutReportIncludesProductionCohortControlPlaneRows() {
        let upload = rolloutReadinessDiagnostics()

        let text = AppState.canonicalReadRolloutReportText(upload)

        XCTAssertTrue(text.contains("Production Cohort Control Plane"))
        XCTAssertTrue(text.contains("- cohort_rollout_stage: blocked"))
        XCTAssertTrue(text.contains("- cohort approval state: not_requested"))
        XCTAssertTrue(text.contains("- cohort eligibility: blocked"))
        XCTAssertTrue(text.contains("- production-wide disabled confirmation: true"))
        XCTAssertTrue(text.contains("does not enable production canonical reads"))
    }

    func testProductionCohortOperatorApprovalDefaultNotRequested() {
        let controlPlane = AppState.makeProductionCohortControlPlaneDiagnostics(
            AppState.SessionSnapshotUploadDiagnostics()
        )

        let approval = AppState.makeProductionCohortOperatorApprovalDiagnostics(controlPlane)

        XCTAssertEqual(approval.state, .notRequested)
        XCTAssertFalse(approval.approvalEligible)
        XCTAssertTrue(approval.approvalBlockedReason?.contains("org_id_required") == true)
        XCTAssertTrue(approval.approvalBlockedReason?.contains("property_id_required") == true)
    }

    func testProductionCohortOperatorApprovalMissingAllowlistBlocksApproval() {
        let upload = rolloutReadinessDiagnostics(
            configuration: AppState.CanonicalReadCandidateConfiguration(
                enabled: true,
                orgAllowlist: [],
                propertyAllowlist: [],
                sessionAllowlist: [],
                parityCompletenessThreshold: 0.95,
                mediaRecoveryConfidenceThreshold: 0.95
            )
        )
        let controlPlane = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID
        )

        let approval = AppState.makeProductionCohortOperatorApprovalDiagnostics(controlPlane)

        XCTAssertFalse(approval.approvalEligible)
        XCTAssertTrue(approval.approvalBlockedReason?.contains("allowlist_incomplete") == true)
    }

    func testProductionCohortOperatorApprovalMissingRollbackBlocksApproval() {
        let upload = rolloutReadinessDiagnostics(rollbackAvailable: false)
        let controlPlane = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID
        )

        let approval = AppState.makeProductionCohortOperatorApprovalDiagnostics(controlPlane)

        XCTAssertFalse(approval.approvalEligible)
        XCTAssertTrue(approval.approvalBlockedReason?.contains("rollback_not_validated") == true)
    }

    func testProductionCohortOperatorApprovalUnresolvedBlockersBlockApproval() {
        let upload = rolloutReadinessDiagnostics(
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
        let controlPlane = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID
        )

        let approval = AppState.makeProductionCohortOperatorApprovalDiagnostics(controlPlane)

        XCTAssertFalse(approval.approvalEligible)
        XCTAssertTrue(approval.approvalBlockedReason?.contains("unresolved_missing_remote_children") == true)
    }

    func testProductionCohortOperatorApprovalPositiveEvidenceCanEnterPendingReview() {
        let upload = rolloutReadinessDiagnostics()
        let controlPlane = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID
        )

        let result = AppState.requestProductionCohortOperatorReview(
            controlPlane,
            requestedAt: Date(timeIntervalSinceReferenceDate: 7_000)
        )

        XCTAssertEqual(result.action, .requestOperatorReview)
        XCTAssertEqual(result.diagnostics.state, .pendingReview)
        XCTAssertTrue(result.diagnostics.approvalEligible)
        XCTAssertNil(result.diagnostics.approvalBlockedReason)
        XCTAssertTrue(result.noBehaviorChangedText.contains("diagnostic approval state only"))
    }

    func testProductionCohortOperatorApprovalRecordsSelectedScopeOnly() {
        let upload = rolloutReadinessDiagnostics()
        let controlPlane = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            )
        )
        let approvedAt = Date(timeIntervalSinceReferenceDate: 7_100)
        let expiresAt = Date(timeIntervalSinceReferenceDate: 7_200)

        let result = AppState.approveProductionCohortReadiness(
            controlPlane,
            approvedAt: approvedAt,
            expiresAt: expiresAt
        )

        XCTAssertEqual(result.action, .approveProductionCohortReadiness)
        XCTAssertEqual(result.diagnostics.state, .approved)
        XCTAssertEqual(result.diagnostics.approvedScope.orgID, orgID)
        XCTAssertEqual(result.diagnostics.approvedScope.propertyID, propertyID)
        XCTAssertEqual(result.diagnostics.approvedScope.sessionID, sessionID)
        XCTAssertEqual(result.diagnostics.approvalTimestamp, approvedAt)
        XCTAssertEqual(result.diagnostics.expirationTimestamp, expiresAt)
        XCTAssertFalse(result.diagnostics.staleApproval)
    }

    func testProductionCohortOperatorApprovalRejectedBlocksReadiness() {
        let upload = rolloutReadinessDiagnostics()
        let controlPlane = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID
        )

        let result = AppState.rejectProductionCohortReadiness(
            controlPlane,
            rejectedAt: Date(timeIntervalSinceReferenceDate: 7_300)
        )

        XCTAssertEqual(result.action, .rejectProductionCohortReadiness)
        XCTAssertEqual(result.diagnostics.state, .rejected)
        XCTAssertFalse(result.diagnostics.approvalEligible)
        XCTAssertTrue(result.diagnostics.approvalBlockedReason?.contains("operator_rejected") == true)
    }

    func testProductionCohortOperatorApprovalExpiredOrStaleBlocksReadiness() {
        let upload = rolloutReadinessDiagnostics()
        let controlPlane = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID
        )
        let approvedAt = Date(timeIntervalSinceReferenceDate: 7_400)
        let expiredAt = Date(timeIntervalSinceReferenceDate: 7_500)
        let checkedAt = Date(timeIntervalSinceReferenceDate: 7_600)

        let approval = AppState.makeProductionCohortOperatorApprovalDiagnostics(
            controlPlane,
            requestedState: .approved,
            approvalTimestamp: approvedAt,
            expirationTimestamp: expiredAt,
            checkedAt: checkedAt
        )

        XCTAssertEqual(approval.state, .expired)
        XCTAssertTrue(approval.staleApproval)
        XCTAssertFalse(approval.approvalEligible)
        XCTAssertTrue(approval.approvalBlockedReason?.contains("operator_approval_expired") == true)
    }

    func testProductionCohortOperatorApprovalReportIncludesLocalHealthFields() {
        let upload = rolloutReadinessDiagnostics()
        let controlPlane = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID
        )
        let approval = AppState.requestProductionCohortOperatorReview(controlPlane).diagnostics

        let report = AppState.productionCohortOperatorApprovalReportText(approval)
        let rolloutReport = AppState.canonicalReadRolloutReportText(upload)

        XCTAssertTrue(report.contains("Production Cohort Operator Approval"))
        XCTAssertTrue(report.contains("- operator_approval_state: pending_review"))
        XCTAssertTrue(report.contains("- approval_eligibility: true"))
        XCTAssertTrue(report.contains("- approved_org_id: \(orgID.uuidString)"))
        XCTAssertTrue(report.contains("- approval_freshness: fresh_or_not_started"))
        XCTAssertTrue(report.contains("- manual_actions: Request Operator Review, Approve Production Cohort Readiness, Reject Production Cohort Readiness"))
        XCTAssertTrue(rolloutReport.contains("Operator Approval Rows"))
        XCTAssertTrue(rolloutReport.contains("- operator approval state: not_requested"))
    }

    func testProductionCohortOperatorApprovalDoesNotChangeProductionCanonicalReadBehavior() {
        let upload = rolloutReadinessDiagnostics()
        let controlPlane = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: orgID
        )

        let result = AppState.approveProductionCohortReadiness(controlPlane)

        XCTAssertTrue(result.diagnostics.noBehaviorChangedText.contains("does not enable production canonical reads"))
        XCTAssertTrue(result.diagnostics.noBehaviorChangedText.contains("activate production candidates"))
        XCTAssertTrue(result.diagnostics.noBehaviorChangedText.contains("switch global canonical reads"))
        XCTAssertTrue(result.diagnostics.noBehaviorChangedText.contains("remove local/iCloud fallback"))
    }

    func testProductionRolloutDryRunDefaultBlocked() {
        let package = AppState.generateProductionRolloutDryRun(
            AppState.SessionSnapshotUploadDiagnostics()
        )

        XCTAssertEqual(package.state, .dryRunBlocked)
        XCTAssertTrue(package.blockers.contains("org_id_required"))
        XCTAssertTrue(package.blockers.contains("property_id_required"))
        XCTAssertEqual(package.localHealthAction, "Generate Production Rollout Dry Run")
        XCTAssertTrue(package.noChangesPerformedText.contains("No changes performed"))
    }

    func testProductionRolloutDryRunMissingAllowlistBlocked() {
        let upload = rolloutReadinessDiagnostics(
            configuration: AppState.CanonicalReadCandidateConfiguration(
                enabled: true,
                orgAllowlist: [],
                propertyAllowlist: [],
                sessionAllowlist: [],
                parityCompletenessThreshold: 0.95,
                mediaRecoveryConfidenceThreshold: 0.95
            )
        )

        let package = AppState.generateProductionRolloutDryRun(upload, orgID: orgID)

        XCTAssertEqual(package.state, .dryRunBlocked)
        XCTAssertTrue(package.blockers.contains("allowlist_incomplete"))
        XCTAssertTrue(package.blockers.contains("candidate_not_ready"))
    }

    func testProductionRolloutDryRunPositiveEvidenceReadyForOperatorReview() {
        let upload = rolloutReadinessDiagnostics()

        let package = AppState.generateProductionRolloutDryRun(upload, orgID: orgID)

        XCTAssertEqual(package.state, .dryRunReadyForOperatorReview)
        XCTAssertTrue(package.blockers.isEmpty)
        XCTAssertTrue(package.parityReplayReady)
        XCTAssertTrue(package.candidateReady)
        XCTAssertTrue(package.overlayReady)
        XCTAssertTrue(package.activationReady)
        XCTAssertTrue(package.rollbackFallbackReady)
        XCTAssertTrue(package.requiredOperatorActions.contains("Request Operator Review"))
    }

    func testProductionRolloutDryRunOperatorApprovedReadyForSingleSessionAllowlist() {
        let upload = rolloutReadinessDiagnostics()

        let package = AppState.generateProductionRolloutDryRun(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            ),
            approvalTimestamp: Date(timeIntervalSinceReferenceDate: 7_700),
            expirationTimestamp: Date(timeIntervalSinceReferenceDate: 8_700),
            checkedAt: Date(timeIntervalSinceReferenceDate: 7_800)
        )

        XCTAssertEqual(package.state, .dryRunReadyForSingleSessionAllowlist)
        XCTAssertTrue(package.blockers.isEmpty)
        XCTAssertEqual(package.operatorApprovalReadiness.state, .approved)
        XCTAssertEqual(package.cohortControlPlane.cohort.activationEligibility, .singleSessionReadinessOnly)
        XCTAssertTrue(package.requiredOperatorActions.contains("copy_dry_run_report_to_operator_rollout_record"))
    }

    func testProductionRolloutDryRunProductionWideEnabledBlocksDryRun() {
        let upload = rolloutReadinessDiagnostics(productionWideEnabled: true)

        let package = AppState.generateProductionRolloutDryRun(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved,
                productionWideEnabled: true
            )
        )

        XCTAssertEqual(package.state, .dryRunBlocked)
        XCTAssertFalse(package.productionWideDisabledConfirmation)
        XCTAssertTrue(package.blockers.contains("production_wide_canonical_reads_not_disabled"))
    }

    func testProductionRolloutDryRunReportIncludesRollbackAndFallbackPlan() {
        let upload = rolloutReadinessDiagnostics()
        let package = AppState.generateProductionRolloutDryRun(upload, orgID: orgID)

        let report = AppState.productionRolloutDryRunReportText(package)
        let rolloutReport = AppState.canonicalReadRolloutReportText(upload)

        XCTAssertTrue(report.contains("Production Rollout Dry Run"))
        XCTAssertTrue(report.contains("- selected_org_id: \(orgID.uuidString)"))
        XCTAssertTrue(report.contains("- rollback_plan: Keep active source local"))
        XCTAssertTrue(report.contains("- fallback_plan: Continue local-first reads"))
        XCTAssertTrue(report.contains("- production_wide_disabled_confirmation: true"))
        XCTAssertTrue(report.contains("No changes performed"))
        XCTAssertTrue(rolloutReport.contains("Production Rollout Dry Run Rows"))
        XCTAssertTrue(rolloutReport.contains("- local health action: Generate Production Rollout Dry Run"))
    }

    func testProductionRolloutDryRunNoBehaviorChangesOccur() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Phase2C27D-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let upload = rolloutReadinessDiagnostics()

        let package = AppState.generateProductionRolloutDryRun(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            )
        )

        XCTAssertTrue(package.noChangesPerformedText.contains("does not enable production reads"))
        XCTAssertTrue(package.noChangesPerformedText.contains("activate candidates"))
        XCTAssertTrue(package.noChangesPerformedText.contains("switch global canonical reads"))
        XCTAssertTrue(package.noChangesPerformedText.contains("write local or remote state"))
        XCTAssertTrue(package.noChangesPerformedText.contains("remove local/iCloud fallback"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
