import XCTest
@testable import ScoutCapture

@MainActor
final class Phase2C25DSnapshotRecoveryCohortTests: XCTestCase {
    private func makeRestoreDiagnostics(
        result: AppState.SessionSnapshotRestoreDiagnosticOutcome = .restorableMetadataCandidate,
        checkedAt: Date = Date(timeIntervalSinceReferenceDate: 10_000),
        snapshotGeneratedAt: Date? = Date(timeIntervalSinceReferenceDate: 9_900),
        localSessionExists: Bool = true,
        localSessionStatus: String? = Session.Status.completed.rawValue,
        localShotCount: Int? = 3,
        localIssueCount: Int? = 1,
        localGuidedCount: Int? = 2,
        snapshotShotCount: Int? = 3,
        snapshotIssueCount: Int? = 1,
        snapshotGuidedCount: Int? = 2,
        snapshotMediaManifestCount: Int? = 3,
        rowFound: Bool = true,
        objectReadable: Bool = true
    ) -> AppState.SessionSnapshotRestoreDiagnosticsResult {
        AppState.SessionSnapshotRestoreDiagnosticsResult(
            checkedAt: checkedAt,
            propertyID: UUID(),
            sessionID: UUID(),
            snapshotID: UUID(),
            result: result,
            failureReason: nil,
            rowFound: rowFound,
            objectReadable: objectReadable,
            checksumVerified: result != .checksumFailed,
            byteSizeMatches: true,
            rowObjectVerified: true,
            parentRemoteVerified: result != .parentMismatch,
            snapshotSchemaVersion: result == .unsupportedSchema ? 99 : 1,
            snapshotCreatedAt: snapshotGeneratedAt,
            snapshotGeneratedAt: snapshotGeneratedAt,
            localSessionExists: localSessionExists,
            localSessionStatus: localSessionStatus,
            localShotCount: localShotCount,
            localIssueCount: localIssueCount,
            localGuidedCount: localGuidedCount,
            snapshotShotCount: snapshotShotCount,
            snapshotIssueCount: snapshotIssueCount,
            snapshotGuidedCount: snapshotGuidedCount,
            snapshotMediaManifestCount: snapshotMediaManifestCount,
            snapshotMissingLocalOriginalsCount: nil,
            snapshotSupabaseStorageMetadataCount: nil,
            freshness: "equal"
        )
    }

    func testCohortClassificationForCompletedSealedSession() {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let result = AppState.makeSnapshotRecoveryCohortResult(
            from: makeRestoreDiagnostics(checkedAt: checkedAt),
            checkedAt: checkedAt
        )

        XCTAssertEqual(result.category, .completedSealedSession)
        XCTAssertEqual(result.readiness, .readyForManualHydration)
        XCTAssertEqual(result.riskLevel, .medium)
        XCTAssertEqual(result.hydrationEligibilityReason, "verified_snapshot_manual_hydration_candidate")
    }

    func testCohortClassificationForDraftSession() {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let result = AppState.makeSnapshotRecoveryCohortResult(
            from: makeRestoreDiagnostics(checkedAt: checkedAt, localSessionStatus: Session.Status.draft.rawValue),
            checkedAt: checkedAt
        )

        XCTAssertEqual(result.category, .draftSession)
        XCTAssertEqual(result.readiness, .readyForManualHydration)
    }

    func testCohortClassificationForHighVolumeMetadata() {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let result = AppState.makeSnapshotRecoveryCohortResult(
            from: makeRestoreDiagnostics(
                checkedAt: checkedAt,
                localShotCount: 150,
                snapshotShotCount: 150,
                snapshotMediaManifestCount: 150
            ),
            checkedAt: checkedAt
        )

        XCTAssertEqual(result.category, .highVolumeMetadata)
        XCTAssertEqual(result.readiness, .readyForManualHydration)
    }

    func testCohortClassificationForNoMediaManifest() {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let result = AppState.makeSnapshotRecoveryCohortResult(
            from: makeRestoreDiagnostics(checkedAt: checkedAt, snapshotMediaManifestCount: 0),
            checkedAt: checkedAt
        )

        XCTAssertEqual(result.category, .noMediaManifest)
    }

    func testCohortClassificationForOrgDriftHistory() {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let result = AppState.makeSnapshotRecoveryCohortResult(
            from: makeRestoreDiagnostics(checkedAt: checkedAt),
            checkedAt: checkedAt,
            hasOrgDriftHistory: true
        )

        XCTAssertEqual(result.category, .orgDriftHistory)
        XCTAssertEqual(result.readiness, .readyForManualHydration)
    }

    func testStaleSnapshotDetectionRequiresReview() {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let oldSnapshot = checkedAt.addingTimeInterval(-(8 * 24 * 60 * 60))

        let result = AppState.makeSnapshotRecoveryCohortResult(
            from: makeRestoreDiagnostics(checkedAt: checkedAt, snapshotGeneratedAt: oldSnapshot),
            checkedAt: checkedAt
        )

        XCTAssertEqual(result.category, .staleSnapshot)
        XCTAssertEqual(result.readiness, .needsReview)
        XCTAssertEqual(result.riskLevel, .medium)
        XCTAssertEqual(result.hydrationEligibilityReason, "snapshot_age_review_required")
    }

    func testMissingLocalMetadataCandidateHandling() {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let result = AppState.makeSnapshotRecoveryCohortResult(
            from: makeRestoreDiagnostics(
                checkedAt: checkedAt,
                localSessionExists: false,
                localSessionStatus: nil,
                localShotCount: nil,
                localIssueCount: nil,
                localGuidedCount: nil
            ),
            checkedAt: checkedAt
        )

        XCTAssertEqual(result.category, .missingLocalMetadata)
        XCTAssertEqual(result.readiness, .readyForManualHydration)
        XCTAssertEqual(result.riskLevel, .low)
    }

    func testRecoveryReadinessScoringBlocksConflictsAndVerificationFailures() {
        let localConflict = AppState.makeSnapshotRecoveryCohortResult(
            from: makeRestoreDiagnostics(result: .localNewerConflict)
        )
        let checksum = AppState.makeSnapshotRecoveryCohortResult(
            from: makeRestoreDiagnostics(result: .checksumFailed)
        )

        XCTAssertEqual(localConflict.category, .localNewerConflict)
        XCTAssertEqual(localConflict.readiness, .blocked)
        XCTAssertEqual(localConflict.riskLevel, .blocking)
        XCTAssertEqual(checksum.category, .blockedVerification)
        XCTAssertEqual(checksum.readiness, .blocked)
        XCTAssertEqual(checksum.hydrationEligibilityReason, "checksum_failed")
    }

    func testNoSnapshotFoundReportsCoverageGap() {
        let result = AppState.makeSnapshotRecoveryCohortResult(
            from: makeRestoreDiagnostics(result: .noSnapshotFound, rowFound: false, objectReadable: false)
        )

        XCTAssertEqual(result.category, .noSnapshotFound)
        XCTAssertEqual(result.readiness, .blocked)
        XCTAssertFalse(result.latestSnapshotCovered)
    }

    func testCohortCheckDoesNotHydrate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C25D-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LocalStore(testStorageRootURL: root)
        let orgID = UUID()
        _ = try store.createOrganization(Organization(id: orgID, name: "Cohort Org"))
        let property = try store.createProperty(Property(id: UUID(), orgId: orgID, name: "Cohort Property"))
        let session = try store.upsertSession(
            Session(
                id: UUID(),
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 100),
                status: .completed,
                endedAt: Date(timeIntervalSinceReferenceDate: 200),
                isSealed: true
            )
        )
        let metadata = SessionMetadata(
            schemaVersion: 12,
            propertyID: property.id,
            sessionID: session.id,
            orgID: orgID,
            propertyNameAtCapture: property.name,
            propertyNameAtExport: nil,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            status: session.status,
            isBaselineSession: false,
            exportedAt: nil,
            isSealed: true,
            firstDeliveredAt: nil,
            reExportExpiresAt: nil,
            appVersion: "test-app",
            deviceModel: "test-device",
            osVersion: "test-os",
            shots: [],
            issues: [],
            guidedShots: []
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)

        let defaults = UserDefaults(suiteName: "ScoutCapture-2C25D-\(UUID().uuidString)") ?? .standard
        defaults.set(true, forKey: "session_snapshot_shadow_write_enabled")
        let artifactAppState = AppState(
            localStore: store,
            userDefaults: defaults,
            environment: [
                "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
                "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key"
            ],
            sessionSnapshotStorageUploadOverride: { _ in },
            sessionSnapshotRowInsertOverride: { _ in },
            disableCloudBackupForTests: true
        )
        let artifacts = try artifactAppState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: property.id,
            sessionID: session.id
        )
        let appState = AppState(
            localStore: store,
            userDefaults: defaults,
            environment: [
                "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
                "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key"
            ],
            sessionSnapshotRowsFetchOverride: { _, _, _ in [artifacts.row] },
            sessionSnapshotStorageDownloadOverride: { _, _ in artifacts.object.payloadData },
            sessionSnapshotRemoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: orgID,
                    sessionOrgID: orgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: true,
                    errorMessage: nil
                )
            },
            disableCloudBackupForTests: true
        )
        appState.selectedPropertyID = property.id
        let before = try Data(contentsOf: store.sessionJSONURL(propertyID: property.id, sessionID: session.id))

        _ = await appState.validateSnapshotRecoveryCohort()

        let after = try Data(contentsOf: store.sessionJSONURL(propertyID: property.id, sessionID: session.id))
        XCTAssertEqual(before, after)
        XCTAssertNil(appState.localDiagnostics.sessionSnapshotUpload.lastHydrationAt)
        XCTAssertFalse(appState.localDiagnostics.sessionSnapshotUpload.lastHydrationAllowed)
    }
}
