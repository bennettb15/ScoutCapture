import XCTest
@testable import ScoutCapture

final class Phase2C26GRemoteNormalizedParityTests: XCTestCase {
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
        localGuidedCount: Int? = 0,
        remotePropertyFound: Bool = true,
        remoteSessionFound: Bool = true,
        localSessionFound: Bool = true,
        countParity: Bool? = true,
        blockedReason: String? = nil
    ) -> AppState.CanonicalReadDiagnosticsResult {
        AppState.CanonicalReadDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 1_000),
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
            localGuidedCount: localGuidedCount,
            remoteGuidedCount: nil,
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 900),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 900),
            remoteRevision: 8,
            remoteFreshnessAgeSeconds: 100,
            canonicalRecommendation: "local_first_block_canonical_read",
            blockedReason: blockedReason,
            noBehaviorChangedText: "read only"
        )
    }

    func testManualFindingShapeClassifiesParentOrgAndMissingRemoteChildren() {
        let report = AppState.makeNormalizedParityGapReport(
            checkedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            canonicalDiagnostics: canonicalDiagnostics(
                result: .parentMismatch,
                parentOrgConsistent: false,
                parentPropertyConsistent: true,
                localShotCount: 3,
                remoteShotCount: 0,
                localIssueObservationCount: 2,
                remoteIssueObservationCount: 0,
                countParity: false,
                blockedReason: "parent_org_or_property_mismatch"
            )
        )

        XCTAssertEqual(report.taxonomy, [.missingRemoteChildren, .parentOrgDivergence, .partialShadowWrite])
        XCTAssertEqual(report.normalizedParityCompleteness, "parents_present_children_missing")
        XCTAssertEqual(report.missingRemoteEntityClassification, "remote_shots_and_observations_missing")
        XCTAssertEqual(report.lineageDivergenceSource, "property_or_session_org_id_differs_from_local_or_active_org")
        XCTAssertTrue(report.parityRepairToolingRecommended)
        XCTAssertTrue(report.canonicalReadsRemainBlocked)
        XCTAssertTrue(report.rolloutBlockers.contains("parent_org_consistency_not_verified"))
        XCTAssertTrue(report.rolloutBlockers.contains("remote_child_row_count_parity_not_verified"))
    }

    func testRemoteMissingLocalSessionClassifiesLegacyLocalOnlySession() {
        let report = AppState.makeNormalizedParityGapReport(
            canonicalDiagnostics: canonicalDiagnostics(
                result: .remoteMissing,
                remotePropertyFound: false,
                remoteSessionFound: false,
                countParity: nil,
                blockedReason: "remote_property_or_session_missing"
            )
        )

        XCTAssertTrue(report.taxonomy.contains(.legacyLocalOnlySession))
        XCTAssertEqual(report.normalizedParityCompleteness, "remote_normalized_projection_missing")
        XCTAssertEqual(report.remoteShadowWriteCoverage, "no_remote_parent_shadow_write_coverage_for_checked_scope")
        XCTAssertTrue(report.canonicalReadsRemainBlocked)
    }

    func testLocalNewerClassifiesStaleLocalProjectionWithoutRepairRecommendation() {
        let report = AppState.makeNormalizedParityGapReport(
            canonicalDiagnostics: canonicalDiagnostics(
                result: .localNewerConflict,
                blockedReason: "local_updated_at_newer_than_remote"
            )
        )

        XCTAssertEqual(report.taxonomy, [.staleLocalProjection])
        XCTAssertFalse(report.parityRepairToolingRecommended)
        XCTAssertTrue(report.canonicalReadsRemainBlocked)
    }

    func testMatchingRemoteScopeHasNoParityGap() {
        let report = AppState.makeNormalizedParityGapReport(
            canonicalDiagnostics: canonicalDiagnostics(
                result: .remoteMatchesLocal,
                blockedReason: nil
            )
        )

        XCTAssertTrue(report.taxonomy.isEmpty)
        XCTAssertEqual(report.normalizedParityCompleteness, "complete_for_checked_scope")
        XCTAssertEqual(report.missingRemoteEntityClassification, "none_detected")
        XCTAssertFalse(report.parityRepairToolingRecommended)
        XCTAssertFalse(report.canonicalReadsRemainBlocked)
    }

    func testParityReportTextIsReadOnlyAndSanitized() {
        let report = AppState.makeNormalizedParityGapReport(
            canonicalDiagnostics: canonicalDiagnostics(
                result: .parentMismatch,
                parentOrgConsistent: false,
                remoteShotCount: 0,
                remoteIssueObservationCount: 0,
                countParity: false
            )
        )
        let text = AppState.normalizedParityGapReportText(report)

        XCTAssertTrue(text.contains("Remote Normalized Parity Gap"))
        XCTAssertTrue(text.contains("No behavior changed"))
        XCTAssertFalse(text.contains("/Users/"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("auth_token="))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("signed_url="))
    }
}
