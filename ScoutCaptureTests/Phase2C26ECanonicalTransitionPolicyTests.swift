import XCTest
@testable import ScoutCapture

final class Phase2C26ECanonicalTransitionPolicyTests: XCTestCase {
    private func mediaDiagnostics(
        manifestCount: Int = 1,
        recoverableRemoteCount: Int = 1,
        recoverableLocalCount: Int = 0,
        missingCount: Int = 0,
        checksumVerifiedCount: Int = 1,
        checksumMismatchCount: Int = 0,
        unsupportedCount: Int = 0,
        manifestSupported: Bool = true
    ) -> AppState.SessionSnapshotMediaRecoveryDiagnostics {
        AppState.SessionSnapshotMediaRecoveryDiagnostics(
            checkedAt: Date(timeIntervalSinceReferenceDate: 900),
            readiness: "ready",
            planningState: .fullyRecoverable,
            sourcePriority: AppState.SessionSnapshotMediaRecoverySource.defaultPriority,
            retrievalPolicy: .guardrailsOnly,
            manifestSupported: manifestSupported,
            manifestCount: manifestCount,
            originalsCount: manifestCount,
            localFilesPresentCount: recoverableLocalCount,
            remoteStorageMetadataPresentCount: recoverableRemoteCount,
            recoverableRemoteCount: recoverableRemoteCount,
            recoverableLocalCount: recoverableLocalCount,
            missingCount: missingCount,
            missingRemoteStorageMetadataCount: 0,
            missingLocalFileCount: max(0, manifestCount - recoverableLocalCount),
            checksumVerifiedCount: checksumVerifiedCount,
            checksumUnknownCount: 0,
            checksumMismatchCount: checksumMismatchCount,
            unsupportedCount: unsupportedCount,
            notCheckedCount: 0,
            stateCounts: [:],
            items: []
        )
    }

    private func restoreDiagnostics(
        checkedAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        snapshotGeneratedAt: Date = Date(timeIntervalSinceReferenceDate: 940),
        result: AppState.SessionSnapshotRestoreDiagnosticOutcome = .restorableMetadataCandidate,
        checksumVerified: Bool = true,
        rowObjectVerified: Bool = true,
        parentRemoteVerified: Bool = true,
        mediaRecoveryDiagnostics: AppState.SessionSnapshotMediaRecoveryDiagnostics? = nil
    ) -> AppState.SessionSnapshotRestoreDiagnosticsResult {
        AppState.SessionSnapshotRestoreDiagnosticsResult(
            checkedAt: checkedAt,
            propertyID: UUID(),
            sessionID: UUID(),
            snapshotID: UUID(),
            result: result,
            failureReason: nil,
            rowFound: result != .noSnapshotFound,
            objectReadable: result != .objectMissing,
            checksumVerified: checksumVerified,
            byteSizeMatches: true,
            rowObjectVerified: rowObjectVerified,
            parentRemoteVerified: parentRemoteVerified,
            snapshotSchemaVersion: 1,
            snapshotCreatedAt: snapshotGeneratedAt,
            snapshotGeneratedAt: snapshotGeneratedAt,
            localSessionExists: true,
            localSessionStatus: Session.Status.completed.rawValue,
            localShotCount: 1,
            localIssueCount: 0,
            localGuidedCount: 0,
            snapshotShotCount: 1,
            snapshotIssueCount: 0,
            snapshotGuidedCount: 0,
            snapshotMediaManifestCount: mediaRecoveryDiagnostics?.manifestCount ?? 1,
            snapshotMissingLocalOriginalsCount: mediaRecoveryDiagnostics?.missingLocalFileCount ?? 1,
            snapshotSupabaseStorageMetadataCount: mediaRecoveryDiagnostics?.remoteStorageMetadataPresentCount ?? 1,
            freshness: "fresh",
            mediaRecoveryDiagnostics: mediaRecoveryDiagnostics ?? mediaDiagnostics()
        )
    }

    private func recoveryCohort(
        readiness: AppState.SnapshotRecoveryReadiness = .readyForManualHydration
    ) -> AppState.SnapshotRecoveryCohortResult {
        AppState.SnapshotRecoveryCohortResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            propertyID: UUID(),
            sessionID: UUID(),
            snapshotID: UUID(),
            category: .completedSealedSession,
            readiness: readiness,
            riskLevel: .low,
            snapshotFreshnessAgeSeconds: 60,
            hydrationEligibilityReason: "eligible",
            latestSnapshotCovered: true,
            restoreDiagnosticsResult: AppState.SessionSnapshotRestoreDiagnosticOutcome.restorableMetadataCandidate.rawValue
        )
    }

    private func hydrationPolicy(available: Bool = true) -> AppState.SessionSnapshotHydrationPolicyDiagnostics {
        AppState.SessionSnapshotHydrationPolicyDiagnostics(
            hydrationAvailable: available,
            productionHydrationAllowed: false,
            hydrationMode: "manual_local_only",
            hydrationScope: "metadata_only",
            productionHydrationBlockedReason: "production_hydration_gate_disabled"
        )
    }

    func testCanonicalReadStatesTaxonomyIsExplicit() {
        XCTAssertEqual(
            Set(AppState.CanonicalReadState.allCases.map(\.rawValue)),
            Set([
                "local_only",
                "local_preferred_remote_verified",
                "remote_candidate",
                "remote_canonical",
                "recovery_mode",
                "conflict_mode"
            ])
        )
    }

    func testVerifiedSnapshotWithRecoverableMediaBecomesRemoteCandidateOnly() {
        let diagnostics = AppState.makeCanonicalTransitionPolicyDiagnostics(
            checkedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            restoreDiagnostics: restoreDiagnostics(),
            recoveryCohort: recoveryCohort(),
            hydrationPolicy: hydrationPolicy()
        )

        XCTAssertEqual(diagnostics.readState, .remoteCandidate)
        XCTAssertNotEqual(diagnostics.readState, .remoteCanonical)
        XCTAssertEqual(diagnostics.conflictState, .none)
        XCTAssertEqual(diagnostics.canonicalSourceRecommendation, "local_preferred_remote_candidate")
        XCTAssertEqual(diagnostics.hydrationConfidence, "manual_metadata_hydration_ready")
        XCTAssertEqual(diagnostics.mediaRecoveryConfidence, "recoverable")
        XCTAssertEqual(diagnostics.rolloutPhase, .testOnlyCanonicalReadDiagnostics)
    }

    func testLocalNewerThanRemoteForcesConflictMode() {
        let diagnostics = AppState.makeCanonicalTransitionPolicyDiagnostics(
            restoreDiagnostics: restoreDiagnostics(result: .localNewerConflict),
            recoveryCohort: recoveryCohort(),
            hydrationPolicy: hydrationPolicy()
        )

        XCTAssertEqual(diagnostics.readState, .conflictMode)
        XCTAssertEqual(diagnostics.conflictState, .localNewerThanRemote)
        XCTAssertEqual(diagnostics.canonicalSourceRecommendation, "local_until_operator_review")
    }

    func testStaleSnapshotForcesConflictMode() {
        let diagnostics = AppState.makeCanonicalTransitionPolicyDiagnostics(
            restoreDiagnostics: restoreDiagnostics(result: .staleSnapshot),
            recoveryCohort: recoveryCohort(readiness: .needsReview),
            hydrationPolicy: hydrationPolicy()
        )

        XCTAssertEqual(diagnostics.readState, .conflictMode)
        XCTAssertEqual(diagnostics.conflictState, .staleSnapshot)
    }

    func testPartialMediaRecoveryIsAConflictState() {
        let diagnostics = AppState.makeCanonicalTransitionPolicyDiagnostics(
            restoreDiagnostics: restoreDiagnostics(
                mediaRecoveryDiagnostics: mediaDiagnostics(
                    manifestCount: 3,
                    recoverableRemoteCount: 2,
                    missingCount: 1,
                    checksumVerifiedCount: 2
                )
            ),
            recoveryCohort: recoveryCohort(),
            hydrationPolicy: hydrationPolicy()
        )

        XCTAssertEqual(diagnostics.readState, .conflictMode)
        XCTAssertEqual(diagnostics.conflictState, .partialMediaRecovery)
        XCTAssertEqual(diagnostics.mediaRecoveryConfidence, "partial_missing_media")
    }

    func testNoSnapshotKeepsLocalOnlyRecommendation() {
        let diagnostics = AppState.makeCanonicalTransitionPolicyDiagnostics(
            restoreDiagnostics: restoreDiagnostics(result: .noSnapshotFound),
            recoveryCohort: nil,
            hydrationPolicy: nil
        )

        XCTAssertEqual(diagnostics.readState, .localOnly)
        XCTAssertEqual(diagnostics.canonicalSourceRecommendation, "local_only")
        XCTAssertEqual(diagnostics.conflictState, .none)
    }

    func testTrustHierarchyAndICloudRolesAreReported() {
        let diagnostics = AppState.makeCanonicalTransitionPolicyDiagnostics(
            restoreDiagnostics: restoreDiagnostics(),
            recoveryCohort: recoveryCohort(),
            hydrationPolicy: hydrationPolicy()
        )
        let text = AppState.canonicalTransitionPolicyDiagnosticsText(diagnostics)

        XCTAssertEqual(
            diagnostics.trustHierarchy,
            [
                .activeLocalCaptureSessionState,
                .remoteNormalizedRows,
                .remoteSnapshots,
                .localCacheICloud,
                .exportArchives
            ]
        )
        XCTAssertTrue(text.contains("test_only_canonical_read_diagnostics"))
        XCTAssertTrue(text.contains("unchanged_local_offline_backup_rail"))
        XCTAssertTrue(text.contains("secondary_recovery_offline_continuity"))
        XCTAssertTrue(text.contains("optional_redundancy_after_supabase_recovery_is_proven"))
        XCTAssertTrue(text.contains("does not switch canonical reads"))
    }
}
