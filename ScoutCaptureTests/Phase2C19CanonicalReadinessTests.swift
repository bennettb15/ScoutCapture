import XCTest
@testable import ScoutCapture

final class Phase2C19CanonicalReadinessTests: XCTestCase {
    private func cleanDiagnostics(
        retryableFailed: Int = 0,
        acknowledgedHistorical: Int = 0,
        pendingQueue: Int = 0
    ) -> AppState.LocalDiagnosticsState {
        var diagnostics = AppState.LocalDiagnosticsState()
        diagnostics.offlineQueue.failedCount = retryableFailed
        diagnostics.offlineQueue.acknowledgedHistoricalCount = acknowledgedHistorical
        diagnostics.offlineQueue.pendingCount = pendingQueue
        return diagnostics
    }

    private func emptyDivergenceSummary(orgID: UUID) -> AppState.DivergenceAuditSummary {
        AppState.DivergenceAuditSummary(
            ranAt: Date(timeIntervalSinceReferenceDate: 100),
            activeOrganizationID: orgID,
            remoteScopeAvailable: true,
            localPropertyCount: 1,
            remotePropertyCount: 1,
            localSessionCount: 1,
            remoteSessionCount: 1,
            localShotCount: 0,
            remoteShotCount: 0,
            matchedPropertyCount: 1,
            matchedSessionCount: 1,
            matchedShotCount: 0,
            localOnlyPropertyCount: 0,
            remoteOnlyPropertyCount: 0,
            localOnlySessionCount: 0,
            remoteOnlySessionCount: 0,
            localOnlyShotCount: 0,
            remoteOnlyShotCount: 0,
            staleOrgReconciledPropertyCount: 0,
            staleOrgReconciledShotCount: 0,
            items: []
        )
    }

    private func remoteOnlyReport(
        orgID: UUID,
        classification: AppState.DivergenceDebtClassification,
        labels: [AppState.RemoteOnlySessionDetailLabel] = []
    ) -> AppState.RemoteOnlySessionDetailReport {
        let propertyID = UUID()
        let sessionID = UUID()
        return AppState.RemoteOnlySessionDetailReport(
            inspectedAt: Date(timeIntervalSinceReferenceDate: 200),
            activeOrganizationID: orgID,
            remoteScopeAvailable: true,
            unavailableReason: nil,
            items: [
                AppState.RemoteOnlySessionDetailItem(
                    id: sessionID,
                    sessionID: sessionID,
                    propertyID: propertyID,
                    orgID: orgID,
                    remoteStatus: "draft",
                    startedAt: "2026-01-01T00:00:00Z",
                    completedAt: nil,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 201),
                    deletedAt: nil,
                    captureProfile: nil,
                    parentPropertyExistsLocally: true,
                    localPropertyName: "Test",
                    localSessionRowExists: false,
                    localSessionFolderExists: false,
                    localSessionJSONExists: false,
                    localOriginalsFolderExists: false,
                    remoteShotCount: 0,
                    remoteIssueObservationCount: 0,
                    remoteShotsWithStoragePathCount: 0,
                    remoteShotsMissingStoragePathCount: 0,
                    appearsDeleted: false,
                    appearsStale: false,
                    appearsDraft: true,
                    appearsCompleted: false,
                    classification: classification,
                    classificationReason: "test",
                    labels: labels
                )
            ]
        )
    }

    private func cleanReport(
        orgID: UUID = UUID(),
        diagnostics: AppState.LocalDiagnosticsState? = nil,
        retryCappedMediaCount: Int = 0,
        pendingMediaCount: Int = 0,
        mediaRecoveryCandidateCount: Int? = 0,
        remoteOnlySessionDetailReport: AppState.RemoteOnlySessionDetailReport? = nil
    ) -> AppState.CanonicalReadinessReport {
        AppState.makeCanonicalReadinessReport(
            inspectedAt: Date(timeIntervalSinceReferenceDate: 300),
            activeOrganizationID: orgID,
            diagnostics: diagnostics ?? cleanDiagnostics(),
            retryCappedMediaCount: retryCappedMediaCount,
            pendingMediaCount: pendingMediaCount,
            mediaRecoveryCandidateCount: mediaRecoveryCandidateCount,
            divergenceAuditSummary: emptyDivergenceSummary(orgID: orgID),
            syncDebtInspectionReport: nil,
            remoteOnlySessionDetailReport: remoteOnlySessionDetailReport ?? AppState.RemoteOnlySessionDetailReport(
                inspectedAt: Date(timeIntervalSinceReferenceDate: 250),
                activeOrganizationID: orgID,
                remoteScopeAvailable: true,
                unavailableReason: nil,
                items: []
            )
        )
    }

    func testCanonicalReadinessPassesQueueAndMediaWhenCountsAreClean() {
        let report = cleanReport()

        XCTAssertEqual(report.overallStatus, .notReadyForBroadCanonicalReads)
        XCTAssertEqual(report.sections.first { $0.id == "queue_health" }?.status, .pass)
        XCTAssertEqual(report.sections.first { $0.id == "media_health" }?.status, .pass)
    }

    func testAcknowledgedHistoricalDebtDoesNotBlockReadiness() {
        let report = cleanReport(diagnostics: cleanDiagnostics(acknowledgedHistorical: 4))

        let queue = report.sections.first { $0.id == "queue_health" }
        XCTAssertEqual(queue?.status, .pass)
        XCTAssertEqual(queue?.rows.first { $0.id == "acknowledged_historical_queue_debt" }?.status, .warn)
        XCTAssertEqual(report.overallStatus, .notReadyForBroadCanonicalReads)
    }

    func testPendingMediaBlocksMediaReadiness() {
        let report = cleanReport(pendingMediaCount: 1)

        XCTAssertEqual(report.sections.first { $0.id == "media_health" }?.status, .block)
        XCTAssertEqual(report.overallStatus, .blocked)
    }

    func testMissingLocalHydrationBlocksDivergenceReadiness() {
        let orgID = UUID()
        let report = cleanReport(
            orgID: orgID,
            remoteOnlySessionDetailReport: remoteOnlyReport(orgID: orgID, classification: .missingLocalHydration)
        )

        XCTAssertEqual(report.sections.first { $0.id == "divergence_health" }?.status, .block)
        XCTAssertEqual(report.overallStatus, .blocked)
    }

    func testEmptyRemoteDraftShellDoesNotBlockDivergenceReadiness() {
        let orgID = UUID()
        let report = cleanReport(
            orgID: orgID,
            remoteOnlySessionDetailReport: remoteOnlyReport(
                orgID: orgID,
                classification: .emptyRemoteDraftShell,
                labels: [.cautionDraftIncomplete, .notRecommendedForHydration]
            )
        )

        XCTAssertEqual(report.sections.first { $0.id == "divergence_health" }?.status, .pass)
        XCTAssertEqual(report.overallStatus, .notReadyForBroadCanonicalReads)
    }

    func testSessionIssuesGuidedAndExportRemainBlockedByDesign() {
        let report = cleanReport()

        XCTAssertEqual(report.sections.first { $0.id == "session_metadata" }?.status, .block)
        XCTAssertEqual(report.sections.first { $0.id == "issues_guided" }?.status, .block)
        XCTAssertEqual(report.sections.first { $0.id == "export_scoutprocess" }?.status, .block)
    }

    func testPropertyOpenFreshnessIsScopedPartialWhileBroadCanonicalReadsRemainNotReady() {
        let report = cleanReport()
        let uxFreshness = report.sections.first { $0.id == "ux_freshness" }
        let freshnessRow = uxFreshness?.rows.first { $0.id == "freshness_check" }
        let conflictRow = uxFreshness?.rows.first { $0.id == "conflict_rules" }

        XCTAssertEqual(report.overallStatus, .notReadyForBroadCanonicalReads)
        XCTAssertEqual(uxFreshness?.status, .block)
        XCTAssertEqual(freshnessRow?.status, .warn)
        XCTAssertEqual(freshnessRow?.value, "scoped property-only implemented")
        XCTAssertEqual(
            freshnessRow?.detail,
            "Checks Supabase property row on open without auto-merge; broader child metadata freshness remains deferred."
        )
        XCTAssertNotEqual(freshnessRow?.value, "not implemented")
        XCTAssertEqual(conflictRow?.status, .block)
        XCTAssertEqual(conflictRow?.value, "deferred")
    }

    func testCanonicalReadinessReportTextDescribesScopedPropertyOpenFreshness() {
        let report = cleanReport()
        let text = AppState.canonicalReadinessReportText(report)

        XCTAssertTrue(text.contains("Property open freshness check"))
        XCTAssertTrue(text.contains("scoped property-only implemented"))
        XCTAssertTrue(text.contains("without auto-merge"))
        XCTAssertTrue(text.contains("broader child metadata freshness remains deferred"))
        XCTAssertTrue(text.contains("Web portal conflict rules"))
        XCTAssertTrue(text.contains("deferred"))
        XCTAssertFalse(text.contains("Property open freshness check | block | not implemented"))
    }

    func testCanonicalReadinessReportTextRedactsSensitiveValues() {
        let report = AppState.CanonicalReadinessReport(
            inspectedAt: Date(timeIntervalSinceReferenceDate: 400),
            activeOrganizationID: UUID(),
            overallStatus: .notReadyForBroadCanonicalReads,
            sections: [
                AppState.CanonicalReadinessSection(
                    id: "redaction",
                    title: "Redaction",
                    status: .warn,
                    summary: "path /private/tmp/secret token abc https://example.test/file?signature=secret",
                    rows: [
                        AppState.CanonicalReadinessRow(
                            id: "sensitive",
                            label: "Sensitive",
                            status: .warn,
                            value: "authorization=abc",
                            detail: "signedUrl=https://example.test/file?signature=secret /Users/example/file"
                        )
                    ]
                )
            ],
            recommendedNextSlices: ["Avoid token=abc in reports."],
            noBehaviorChangedText: "No behavior changed."
        )

        let text = AppState.canonicalReadinessReportText(report)
        XCTAssertTrue(text.contains("[path]"))
        XCTAssertTrue(text.contains("[redacted]"))
        XCTAssertTrue(text.contains("[url]"))
        XCTAssertFalse(text.contains("/private/tmp"))
        XCTAssertFalse(text.contains("signature=secret"))
        XCTAssertFalse(text.contains("authorization=abc"))
        XCTAssertFalse(text.contains("token=abc"))
    }

    func testCanonicalReadinessReportCreationIsReadOnlyByConstruction() {
        let diagnostics = cleanDiagnostics()
        let report = cleanReport(diagnostics: diagnostics)

        XCTAssertEqual(diagnostics.offlineQueue.failedCount, 0)
        XCTAssertTrue(AppState.canonicalReadinessReportText(report).contains("No behavior changed"))
        XCTAssertTrue(AppState.canonicalReadinessReportText(report).contains("does not switch canonical reads"))
    }
}
