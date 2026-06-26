import XCTest
@testable import ScoutCapture

final class Phase2C26PFlaggedObservationReplayTests: XCTestCase {
    private let orgID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let propertyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let issueID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let shotID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    private struct AppFixture {
        let appState: AppState
        let defaults: UserDefaults
        let suiteName: String
        let storageRoot: URL
    }

    @MainActor
    private func makeAppFixture(
        environment: [String: String] = [:],
        canonicalReadRemoteSnapshotFetchOverride: AppState.CanonicalReadRemoteSnapshotFetchOverride? = nil
    ) throws -> AppFixture {
        let suiteName = "Phase2C26PFlaggedObservationReplayTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C26P-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let appState = AppState(
            localStore: LocalStore(testStorageRootURL: storageRoot),
            userDefaults: defaults,
            environment: environment,
            canonicalReadRemoteSnapshotFetchOverride: canonicalReadRemoteSnapshotFetchOverride,
            disableCloudBackupForTests: true
        )
        return AppFixture(
            appState: appState,
            defaults: defaults,
            suiteName: suiteName,
            storageRoot: storageRoot
        )
    }

    @MainActor
    private func tearDownAppFixture(_ fixture: AppFixture) {
        fixture.appState.shutdown()
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private var selectedSessionReplayEnvironment: [String: String] {
        [
            SupabaseRuntimeConfiguration.canonicalReadCandidateEnabledEnvKey: "true",
            SupabaseRuntimeConfiguration.canonicalReadCandidateOrgAllowlistEnvKey: orgID.uuidString,
            SupabaseRuntimeConfiguration.canonicalReadCandidatePropertyAllowlistEnvKey: propertyID.uuidString,
            SupabaseRuntimeConfiguration.canonicalReadCandidateSessionAllowlistEnvKey: sessionID.uuidString
        ]
    }

    private var selectedSessionReplayProductionValidationEnvironment: [String: String] {
        var environment = selectedSessionReplayEnvironment
        environment["SCOUTCAPTURE_SUPABASE_URL"] = "https://\(SupabaseRuntimeConfiguration.productionSnapshotValidationProjectRef).supabase.co"
        environment["SCOUTCAPTURE_SUPABASE_ANON_KEY"] = "production-validation-anon-key"
        environment[SupabaseRuntimeConfiguration.productionSnapshotValidationEnvKey] = "true"
        return environment
    }

    @MainActor
    private func configureSelectedSessionReplayFixture(_ fixture: AppFixture) {
        _ = try? fixture.appState.sharedLocalStore.createOrganization(
            Organization(id: orgID, name: "Replay Org")
        )
        _ = try? fixture.appState.sharedLocalStore.createProperty(
            Property(
                id: propertyID,
                orgId: orgID,
                clientName: nil,
                clientPhone: nil,
                clientEmail: nil,
                name: "Replay Property",
                address: nil,
                street: nil,
                city: nil,
                state: nil,
                zip: nil
            )
        )
        let selectedSession = Session(
            id: sessionID,
            propertyID: propertyID,
            startedAt: Date(timeIntervalSinceReferenceDate: 10_000),
            status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            isSealed: true
        )
        _ = try? fixture.appState.sharedLocalStore.upsertSession(selectedSession)
        fixture.appState._debugRefreshPropertiesLocallyForTests()
        fixture.appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(
                    id: orgID,
                    name: "Replay Org",
                    role: "owner"
                )
            ],
            activeOrganizationID: orgID,
            ready: true
        )
        fixture.appState.selectedPropertyID = propertyID
        fixture.appState.currentSession = selectedSession
        var diagnostics = fixture.appState._debugLocalDiagnosticsForTests()
        diagnostics.sessionSnapshotUpload.lastCanonicalReadDiagnosticsVerifiedOrgID = orgID
        diagnostics.sessionSnapshotUpload.lastCanonicalReadDiagnosticsPropertyID = propertyID
        diagnostics.sessionSnapshotUpload.lastCanonicalReadDiagnosticsSessionID = sessionID
        diagnostics.sessionSnapshotUpload.lastCanonicalReadDiagnosticsParentOrgConsistent = true
        diagnostics.sessionSnapshotUpload.lastCanonicalReadDiagnosticsParentPropertyConsistent = true
        diagnostics.sessionSnapshotUpload.lastCanonicalReadDiagnosticsLocalIssueObservationCount = 1
        diagnostics.sessionSnapshotUpload.lastCanonicalReadDiagnosticsRemoteIssueObservationCount = 0
        diagnostics.sessionSnapshotUpload.lastMissingChildCount = 1
        diagnostics.sessionSnapshotUpload.lastNormalizedParityGapTaxonomy = [
            AppState.NormalizedParityGap.missingRemoteChildren.rawValue
        ]
        diagnostics.sessionSnapshotUpload.lastMissingRemoteEntityClassification = "missing_remote_children"
        diagnostics.sessionSnapshotUpload.lastNormalizedBackfillEligible = true
        diagnostics.sessionSnapshotUpload.lastNormalizedBackfillPlannedObservationUpserts = 1
        diagnostics.sessionSnapshotUpload.lastNormalizedBackfillExecutedEntityCount = 0
        diagnostics.sessionSnapshotUpload.lastNormalizedBackfillSkippedEntityCount = 0
        diagnostics.sessionSnapshotUpload.lastNormalizedBackfillProductionBlocked = true
        diagnostics.sessionSnapshotUpload.lastCanonicalReadCandidateProductionWideEnabled = false
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateActivationActiveSource = "local"
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateActivationScope = "selected_session_only"
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateActivationProductionBlocked = true
        fixture.appState._debugSetLocalDiagnosticsForTests(diagnostics)
    }

    @MainActor
    private func selectDifferentSessionDuringReplay(_ fixture: AppFixture) -> (propertyID: UUID, sessionID: UUID) {
        let otherPropertyID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let otherSessionID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        _ = try? fixture.appState.sharedLocalStore.createProperty(
            Property(
                id: otherPropertyID,
                orgId: orgID,
                clientName: nil,
                clientPhone: nil,
                clientEmail: nil,
                name: "Wrong Replay Property",
                address: nil,
                street: nil,
                city: nil,
                state: nil,
                zip: nil
            )
        )
        let otherSession = Session(
            id: otherSessionID,
            propertyID: otherPropertyID,
            startedAt: Date(timeIntervalSinceReferenceDate: 20_000),
            status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 20_600),
            isSealed: true
        )
        _ = try? fixture.appState.sharedLocalStore.upsertSession(otherSession)
        fixture.appState._debugRefreshPropertiesLocallyForTests()
        fixture.appState.selectedPropertyID = otherPropertyID
        fixture.appState.currentSession = otherSession
        return (otherPropertyID, otherSessionID)
    }

    private func canonicalRemoteSnapshot(
        propertyID: UUID,
        sessionID: UUID,
        status: String = "completed",
        shotCount: Int = 10,
        observationCount: Int = 1
    ) -> AppState.CanonicalReadRemoteSnapshot {
        AppState.CanonicalReadRemoteSnapshot(
            properties: [
                AppState.CanonicalReadRemotePropertyRow(
                    id: propertyID,
                    orgID: orgID,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 11_900),
                    revision: 1,
                    deletedAt: nil
                )
            ],
            sessions: [
                AppState.CanonicalReadRemoteSessionRow(
                    id: sessionID,
                    orgID: orgID,
                    propertyID: propertyID,
                    status: status,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 11_900),
                    revision: 1,
                    deletedAt: nil
                )
            ],
            shots: (0..<shotCount).map { _ in
                AppState.CanonicalReadRemoteShotRow(id: UUID(), sessionID: sessionID, deletedAt: nil)
            },
            observations: (0..<observationCount).map { index in
                AppState.CanonicalReadRemoteObservationRow(
                    id: index == 0 ? issueID : UUID(),
                    orgID: orgID,
                    propertyID: propertyID,
                    sessionID: sessionID,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
                    deletedAt: nil
                )
            }
        )
    }

    private func completedLocalSession(
        propertyID: UUID? = nil,
        sessionID: UUID? = nil
    ) -> Session {
        Session(
            id: sessionID ?? self.sessionID,
            propertyID: propertyID ?? self.propertyID,
            startedAt: Date(timeIntervalSinceReferenceDate: 10_000),
            status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            isSealed: true
        )
    }

    private func remoteLifecycleSession(
        orgID: UUID? = nil,
        propertyID: UUID? = nil,
        sessionID: UUID? = nil,
        status: String = "draft",
        completedAt: Date? = nil,
        exportedAt: Date? = nil,
        isSealed: Bool? = false,
        firstDeliveredAt: Date? = nil,
        reExportExpiresAt: Date? = nil,
        updatedAt: Date? = Date(timeIntervalSinceReferenceDate: 10_100),
        deletedAt: Date? = nil
    ) -> AppState.NormalizedSessionLifecycleRemoteRow {
        AppState.NormalizedSessionLifecycleRemoteRow(
            id: sessionID ?? self.sessionID,
            orgID: orgID ?? self.orgID,
            propertyID: propertyID ?? self.propertyID,
            status: status,
            completedAt: completedAt,
            exportedAt: exportedAt,
            isSealed: isSealed,
            firstDeliveredAt: firstDeliveredAt,
            reExportExpiresAt: reExportExpiresAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    private func passingPackageValidationReport(
        scope: AppState.ProductionCohortApprovalScope? = nil,
        packageBlockers: [String] = [],
        rollbackBlockers: [String] = []
    ) -> AppState.LocalHealthSessionSnapshotPackageValidationReport {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 9_500)
        let snapshotID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let targetScope = scope ?? AppState.ProductionCohortApprovalScope(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID
        )
        let packageParity = AppState.ProductionSingleSessionSnapshotPackageParityValidation(
            checkedAt: checkedAt,
            state: packageBlockers.isEmpty ? .testOnlyPackageParityPassed : .blocked,
            blockers: packageBlockers,
            targetScope: targetScope,
            snapshotID: snapshotID,
            restoreDiagnosticsPassed: packageBlockers.isEmpty,
            rowObjectChecksumSchemaParentFreshnessPassed: packageBlockers.isEmpty,
            scopeMatched: packageBlockers.isEmpty,
            hydrationSucceeded: packageBlockers.isEmpty,
            hydratedMetadataMatchesSnapshotEvidence: packageBlockers.isEmpty,
            hydratedShotIDsMatchSnapshotEvidence: packageBlockers.isEmpty,
            hydratedIssueIDsMatchSnapshotEvidence: packageBlockers.isEmpty,
            hydratedGuidedIDsMatchSnapshotEvidence: packageBlockers.isEmpty,
            mediaManifestCount: 1,
            mediaRetrievalAcceptedCount: 1,
            mediaRestorationAcceptedCount: 1,
            mediaChecksumParityPassed: packageBlockers.isEmpty,
            candidateEvidenceReady: packageBlockers.isEmpty,
            overlayEvidenceReady: packageBlockers.isEmpty,
            overlayComparisonMatchesHydratedPackage: packageBlockers.isEmpty,
            fallbackRetained: true,
            activeSourceRemainsLocal: true,
            productionReadsBlocked: true,
            broadCanonicalReadsBlocked: true,
            remoteStateWritesBlocked: true,
            realLocalUserStateWritesBlocked: true,
            originalsOverwriteBlocked: true,
            originalsPreserved: true,
            rollbackCleanupVerified: true,
            noProductionBehaviorChangedText: "test package evidence only; no production behavior changed"
        )
        let rollback = AppState.ProductionSingleSessionFullyRestoredPackageRollbackValidation(
            checkedAt: checkedAt,
            state: rollbackBlockers.isEmpty ? .testOnlyFullyRestoredPackageRollbackPassed : .blocked,
            blockers: rollbackBlockers,
            targetScope: targetScope,
            snapshotID: snapshotID,
            restoreDiagnosticsPassed: rollbackBlockers.isEmpty,
            hydrationSucceeded: rollbackBlockers.isEmpty,
            mediaRetrievalSucceeded: rollbackBlockers.isEmpty,
            mediaRestorationSucceeded: rollbackBlockers.isEmpty,
            mediaRollbackSucceeded: rollbackBlockers.isEmpty,
            preHydrationFixtureFingerprint: "pre-fixture",
            restoredFixtureFingerprint: "pre-fixture",
            preHydrationLocalFixtureRestored: rollbackBlockers.isEmpty,
            generatedRecoveredMediaArtifactsRemoved: true,
            generatedPackageCandidateArtifactsRemoved: true,
            originalsPreserved: true,
            fallbackRetained: true,
            activeSourceRemainsLocal: true,
            productionReadsBlocked: true,
            broadCanonicalReadsBlocked: true,
            activationBlocked: true,
            remoteStateWritesBlocked: true,
            realLocalUserStateWritesBlocked: true,
            exportSealSyncMediaICloudUnchanged: true,
            schemaRLSDataUnchanged: true,
            noProductionBehaviorChangedText: "test rollback evidence only; no production behavior changed"
        )
        return AppState.LocalHealthSessionSnapshotPackageValidationReport(
            checkedAt: checkedAt,
            targetScope: targetScope,
            snapshotID: snapshotID,
            packageParity: packageParity,
            fullyRestoredRollback: rollback,
            packageParityReportText: "package parity passed",
            fullyRestoredRollbackReportText: "fully restored rollback passed",
            combinedReportText: "package parity passed\nfully restored rollback passed"
        )
    }

    private func metadata(
        orgID: UUID? = nil,
        propertyID: UUID? = nil,
        sessionID: UUID? = nil,
        status: Session.Status = .completed,
        issueStatus: String = "active",
        includeShot: Bool = true
    ) -> SessionMetadata {
        let targetPropertyID = propertyID ?? self.propertyID
        let targetSessionID = sessionID ?? self.sessionID
        let shot = ShotMetadata(
            shotID: shotID,
            propertyID: targetPropertyID,
            sessionID: targetSessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 10_100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_200),
            building: "A",
            elevation: "North",
            detailType: "Door",
            angleIndex: 1,
            priority: "High",
            shotKey: "a|north|door|1",
            isGuided: false,
            isFlagged: true,
            issueID: issueID,
            issueStatus: issueStatus,
            captureKind: "captured",
            firstCaptureKind: "captured",
            noteText: "Door trim gap",
            noteCategory: nil,
            originalFilename: "door.jpg",
            originalRelativePath: "Originals/door.jpg",
            originalByteSize: 12,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: nil,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )
        let issue = IssueMetadata(
            issueID: issueID,
            issueStatus: issueStatus,
            currentReason: "Door trim gap",
            firstSeenAt: Date(timeIntervalSinceReferenceDate: 10_100),
            lastSeenAt: Date(timeIntervalSinceReferenceDate: 10_250),
            lastCaptureSessionId: targetSessionID,
            detailNote: "Flagged observation should replay",
            shotKey: "a|north|door|1"
        )
        return SessionMetadata(
            schemaVersion: 1,
            propertyID: targetPropertyID,
            sessionID: targetSessionID,
            orgID: orgID ?? self.orgID,
            propertyNameAtCapture: "Replay Property",
            propertyNameAtExport: "Replay Property",
            startedAt: Date(timeIntervalSinceReferenceDate: 10_000),
            endedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            status: status,
            isBaselineSession: false,
            exportedAt: nil,
            isSealed: true,
            appVersion: "test",
            deviceModel: "test",
            osVersion: "test",
            shots: includeShot ? [shot] : [],
            issues: [issue]
        )
    }

    private func remoteProperties(orgID: UUID? = nil) -> [AppState.CanonicalReadRemotePropertyRow] {
        [
            AppState.CanonicalReadRemotePropertyRow(
                id: propertyID,
                orgID: orgID ?? self.orgID,
                updatedAt: Date(timeIntervalSinceReferenceDate: 10_500),
                revision: 1,
                deletedAt: nil
            )
        ]
    }

    private func remoteSessions(
        orgID: UUID? = nil,
        propertyID: UUID? = nil,
        sessionID: UUID? = nil,
        status: String = "completed",
        updatedAt: Date? = Date(timeIntervalSinceReferenceDate: 10_600)
    ) -> [AppState.CanonicalReadRemoteSessionRow] {
        [
            AppState.CanonicalReadRemoteSessionRow(
                id: sessionID ?? self.sessionID,
                orgID: orgID ?? self.orgID,
                propertyID: propertyID ?? self.propertyID,
                status: status,
                updatedAt: updatedAt,
                revision: 1,
                deletedAt: nil
            )
        ]
    }

    private func replayPlan(
        metadata: SessionMetadata? = nil,
        remoteObservations: [AppState.CanonicalReadRemoteObservationRow] = []
    ) -> AppState.NormalizedObservationReplayPlan {
        AppState.makeNormalizedObservationReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata ?? self.metadata(),
            remoteProperties: remoteProperties(),
            remoteSessions: remoteSessions(),
            remoteObservations: remoteObservations,
            updatedBy: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
    }

    private func executeInsertOnlyReplay(
        plan: AppState.NormalizedObservationReplayPlan,
        startingRows: [AppState.CanonicalReadRemoteObservationRow]
    ) async -> (
        result: AppState.NormalizedBackfillEntityResult,
        remoteRows: [AppState.CanonicalReadRemoteObservationRow]
    ) {
        var remoteRows = startingRows
        let result = await AppState.executeNormalizedObservationReplayInsertOnlyTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { rows in
            var insertedCount = 0
            var duplicateSkippedCount = 0
            var failedCount = 0
            var message = "observation_rows_inserted"

            for row in rows {
                if remoteRows.contains(where: { $0.id == row.id }) {
                    switch AppState.normalizedObservationInsertDuplicateResolution(
                        row: row,
                        remoteObservations: remoteRows
                    ) {
                    case .idempotentExisting:
                        duplicateSkippedCount += 1
                        message = "observation_duplicate_exact_scope_idempotent"
                    case .newerRemotePreserved:
                        duplicateSkippedCount += 1
                        message = "newer_remote_observations_preserved"
                    case .softDeletedPreserved:
                        duplicateSkippedCount += 1
                        message = "soft_deleted_remote_observations_preserved"
                    case .conflict(let reason):
                        failedCount += 1
                        message = reason
                    case .unavailable:
                        failedCount += 1
                        message = "remote_observation_duplicate_confirmation_missing"
                    }
                    continue
                }

                remoteRows.append(
                    AppState.CanonicalReadRemoteObservationRow(
                        id: row.id,
                        orgID: row.orgID,
                        propertyID: row.propertyID,
                        sessionID: row.sessionID,
                        updatedAt: row.updatedAt,
                        deletedAt: nil
                    )
                )
                insertedCount += 1
            }

            return AppState.NormalizedObservationReplayWriteSummary(
                insertedCount: insertedCount,
                duplicateSkippedCount: duplicateSkippedCount,
                failedCount: failedCount,
                message: message
            )
        }
        return (result, remoteRows)
    }

    @MainActor
    func testSelectedSessionReplayActionWithoutPackageValidationEvidenceBlocks() async throws {
        let fixture = try makeAppFixture(environment: selectedSessionReplayEnvironment)
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)
        var replayCalled = false

        let result = await fixture.appState.replayFlaggedObservationShadowWritesForSelectedSession(
            productionValidationEvidence: nil,
            replayOperation: { _, _ in
                replayCalled = true
                return AppState.NormalizedBackfillEntityResult(
                    kind: .observation,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "unexpected"
                )
            }
        )

        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "package_validation_evidence_required")
        XCTAssertFalse(replayCalled)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillExecutedEntityCount, 0)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillBlockedReason, "package_validation_evidence_required")
    }

    @MainActor
    func testSelectedSessionReplayActionWrongSelectedScopeBlocks() async throws {
        let fixture = try makeAppFixture(environment: selectedSessionReplayEnvironment)
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)
        let wrongScope = AppState.ProductionCohortApprovalScope(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        )
        var replayCalled = false

        let result = await fixture.appState.replayFlaggedObservationShadowWritesForSelectedSession(
            productionValidationEvidence: passingPackageValidationReport(scope: wrongScope),
            replayOperation: { _, _ in
                replayCalled = true
                return AppState.NormalizedBackfillEntityResult(
                    kind: .observation,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "unexpected"
                )
            }
        )

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "package_validation_selected_scope_mismatch")
        XCTAssertFalse(replayCalled)
    }

    @MainActor
    func testSelectedSessionReplayActionInvokesReplayExactlyForSelectedScope() async throws {
        let fixture = try makeAppFixture(environment: selectedSessionReplayEnvironment)
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)
        var requestedPropertyID: UUID?
        var requestedSessionID: UUID?

        let result = await fixture.appState.replayFlaggedObservationShadowWritesForSelectedSession(
            productionValidationEvidence: passingPackageValidationReport(),
            replayOperation: { propertyID, sessionID in
                requestedPropertyID = propertyID
                requestedSessionID = sessionID
                return AppState.NormalizedBackfillEntityResult(
                    kind: .observation,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "observation_rows_inserted"
                )
            }
        )

        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.orgID, orgID)
        XCTAssertEqual(result.propertyID, propertyID)
        XCTAssertEqual(result.sessionID, sessionID)
        XCTAssertEqual(requestedPropertyID, propertyID)
        XCTAssertEqual(requestedSessionID, sessionID)
        XCTAssertEqual(result.replayResult?.upsertedCount, 1)
    }

    @MainActor
    func testSelectedSessionReplayActionUpdatesDisplayedReplayDiagnostics() async throws {
        let fixture = try makeAppFixture(environment: selectedSessionReplayEnvironment)
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)

        let result = await fixture.appState.replayFlaggedObservationShadowWritesForSelectedSession(
            productionValidationEvidence: passingPackageValidationReport(),
            replayOperation: { _, _ in
                AppState.NormalizedBackfillEntityResult(
                    kind: .observation,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "observation_rows_inserted"
                )
            }
        )

        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertTrue(result.allowed)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillPlannedObservationUpserts, 1)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillExecutedEntityCount, 1)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillSkippedEntityCount, 0)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillRemoteNewerConflictCount, 0)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillBlockedReason, "none")
        XCTAssertTrue(diagnostics.lastNormalizedBackfillEligible)
    }

    @MainActor
    func testSelectedSessionReplayActionPreservesMixedInsertAndRemoteNewerCounters() async throws {
        let fixture = try makeAppFixture(environment: selectedSessionReplayEnvironment)
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)

        let result = await fixture.appState.replayFlaggedObservationShadowWritesForSelectedSession(
            productionValidationEvidence: passingPackageValidationReport(),
            replayOperation: { _, _ in
                AppState.NormalizedBackfillEntityResult(
                    kind: .observation,
                    attemptedCount: 2,
                    upsertedCount: 1,
                    skippedCount: 1,
                    failedCount: 0,
                    remoteNewerConflictCount: 1,
                    message: "observation_rows_inserted"
                )
            },
            diagnosticsAfterReplayOperation: {
                self.canonicalDiagnostics(
                    remoteObservationCount: 1,
                    result: .remoteMatchesLocal,
                    recommendation: "remote_candidate_after_replay_validation",
                    countParity: true
                )
            }
        )

        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.replayResult?.upsertedCount, 1)
        XCTAssertEqual(result.replayResult?.skippedCount, 1)
        XCTAssertEqual(result.replayResult?.remoteNewerConflictCount, 1)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillExecutedEntityCount, 1)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillSkippedEntityCount, 1)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillRemoteNewerConflictCount, 1)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillBlockedReason, "none")
    }

    @MainActor
    func testSelectedSessionReplayActionPostReplayDiagnosticsStayPinnedAfterSelectionChanges() async throws {
        var requestedOrgID: UUID?
        var requestedPropertyID: UUID?
        var requestedSessionID: UUID?
        let fixture = try makeAppFixture(
            environment: selectedSessionReplayEnvironment,
            canonicalReadRemoteSnapshotFetchOverride: { orgID, propertyID, sessionID in
                requestedOrgID = orgID
                requestedPropertyID = propertyID
                requestedSessionID = sessionID
                return self.canonicalRemoteSnapshot(
                    propertyID: propertyID ?? self.propertyID,
                    sessionID: sessionID ?? self.sessionID,
                    observationCount: 1
                )
            }
        )
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)
        var wrongSelectedPropertyID: UUID?
        var wrongSelectedSessionID: UUID?

        let result = await fixture.appState.replayFlaggedObservationShadowWritesForSelectedSession(
            productionValidationEvidence: passingPackageValidationReport(),
            replayOperation: { _, _ in
                await MainActor.run {
                    let wrongScope = self.selectDifferentSessionDuringReplay(fixture)
                    wrongSelectedPropertyID = wrongScope.propertyID
                    wrongSelectedSessionID = wrongScope.sessionID
                }
                return AppState.NormalizedBackfillEntityResult(
                    kind: .observation,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "observation_rows_inserted"
                )
            }
        )

        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.diagnosticsAfterReplay?.propertyID, propertyID)
        XCTAssertEqual(result.diagnosticsAfterReplay?.sessionID, sessionID)
        XCTAssertEqual(requestedOrgID, orgID)
        XCTAssertEqual(requestedPropertyID, propertyID)
        XCTAssertEqual(requestedSessionID, sessionID)
        XCTAssertNotEqual(requestedPropertyID, wrongSelectedPropertyID)
        XCTAssertNotEqual(requestedSessionID, wrongSelectedSessionID)
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsPropertyID, propertyID)
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsSessionID, sessionID)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillExecutedEntityCount, 1)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillSkippedEntityCount, 0)
    }

    @MainActor
    func testSelectedSessionReplayActionSuccessfulReplayRefreshesDiagnosticsAndClearsMissingRemoteChildren() async throws {
        let fixture = try makeAppFixture(environment: selectedSessionReplayEnvironment)
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)
        let afterReplayDiagnostics = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .remoteMatchesLocal,
            recommendation: "remote_candidate_after_replay_validation",
            countParity: true
        )
        var diagnosticsRefreshCalled = false

        let result = await fixture.appState.replayFlaggedObservationShadowWritesForSelectedSession(
            productionValidationEvidence: passingPackageValidationReport(),
            replayOperation: { _, _ in
                AppState.NormalizedBackfillEntityResult(
                    kind: .observation,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "observation_rows_inserted"
                )
            },
            diagnosticsAfterReplayOperation: {
                diagnosticsRefreshCalled = true
                return afterReplayDiagnostics
            }
        )

        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertTrue(result.allowed)
        XCTAssertTrue(diagnosticsRefreshCalled)
        XCTAssertEqual(result.diagnosticsAfterReplay?.remoteIssueObservationCount, 1)
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsRemoteIssueObservationCount, 1)
        XCTAssertEqual(diagnostics.lastMissingChildCount, 0)
        XCTAssertFalse(diagnostics.lastNormalizedParityGapTaxonomy.contains(AppState.NormalizedParityGap.missingRemoteChildren.rawValue))
        XCTAssertEqual(diagnostics.lastMissingRemoteEntityClassification, "none_detected")
    }

    @MainActor
    func testSelectedSessionReplayActionDoesNotActivateSwitchReadsOrEnableBroadReads() async throws {
        let fixture = try makeAppFixture(environment: selectedSessionReplayEnvironment)
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)

        let result = await fixture.appState.replayFlaggedObservationShadowWritesForSelectedSession(
            productionValidationEvidence: passingPackageValidationReport(),
            replayOperation: { _, _ in
                AppState.NormalizedBackfillEntityResult(
                    kind: .observation,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "observation_rows_inserted"
                )
            }
        )

        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.replayResult?.upsertedCount, 1)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(diagnostics.lastCanonicalReadCandidateProductionWideEnabled)
        XCTAssertEqual(diagnostics.lastCanonicalCandidateActivationActiveSource, "local")
        XCTAssertNotEqual(diagnostics.lastCanonicalCandidateActivationActiveSource, "canonical_candidate")
        XCTAssertTrue(diagnostics.lastCanonicalReadsRemainBlocked)
        XCTAssertTrue(diagnostics.lastNormalizedBackfillProductionBlocked)
        XCTAssertTrue(diagnostics.lastCanonicalCandidateActivationProductionBlocked)
    }

    @MainActor
    func testSelectedSessionLifecycleReplayWithoutPackageValidationEvidenceBlocks() async throws {
        let fixture = try makeAppFixture(environment: selectedSessionReplayEnvironment)
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)
        var replayCalled = false

        let result = await fixture.appState.replaySelectedSessionLifecycleShadowWriteForSelectedSession(
            productionValidationEvidence: nil,
            replayOperation: { _, _, _ in
                replayCalled = true
                return AppState.NormalizedBackfillEntityResult(
                    kind: .session,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "unexpected"
                )
            }
        )

        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "package_validation_evidence_required")
        XCTAssertFalse(replayCalled)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillPlannedSessionUpserts, 0)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillExecutedEntityCount, 0)
    }

    @MainActor
    func testSelectedSessionLifecycleReplayWrongSelectedScopeBlocks() async throws {
        let fixture = try makeAppFixture(environment: selectedSessionReplayEnvironment)
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)
        let wrongScope = AppState.ProductionCohortApprovalScope(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        )
        var replayCalled = false

        let result = await fixture.appState.replaySelectedSessionLifecycleShadowWriteForSelectedSession(
            productionValidationEvidence: passingPackageValidationReport(scope: wrongScope),
            replayOperation: { _, _, _ in
                replayCalled = true
                return AppState.NormalizedBackfillEntityResult(
                    kind: .session,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "unexpected"
                )
            }
        )

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.blockedReason, "package_validation_selected_scope_mismatch")
        XCTAssertFalse(replayCalled)
    }

    func testSelectedSessionLifecycleReplayUpdatesDraftToCompletedForExactSession() async {
        let plan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(status: "draft")
        )
        var updatedRow: AppState.NormalizedSessionLifecycleReplayRow?

        let result = await AppState.executeNormalizedSessionLifecycleReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { row in
            updatedRow = row
            return AppState.NormalizedSessionLifecycleReplayWriteSummary(
                updatedCount: 1,
                message: "session_lifecycle_replayed"
            )
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertEqual(plan.rowToUpdate?.orgID, orgID)
        XCTAssertEqual(plan.rowToUpdate?.propertyID, propertyID)
        XCTAssertEqual(plan.rowToUpdate?.sessionID, sessionID)
        XCTAssertEqual(plan.rowToUpdate?.status, Session.Status.completed.rawValue)
        XCTAssertEqual(result.upsertedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.remoteNewerConflictCount, 0)
        XCTAssertEqual(updatedRow?.sessionID, sessionID)
    }

    func testSelectedSessionLifecycleReplayPinnedDiagnosticsCompletedVsDraftForcesUpdate() async {
        let staleDraftMetadata = metadata(status: .draft)
        let pinnedDiagnostics = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .divergentConflict,
            recommendation: "local_first_block_canonical_read",
            countParity: true,
            statusParity: false,
            localStatus: Session.Status.completed.rawValue,
            remoteStatus: Session.Status.draft.rawValue
        )
        let plan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: staleDraftMetadata,
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(
                status: Session.Status.draft.rawValue,
                completedAt: staleDraftMetadata.endedAt,
                exportedAt: staleDraftMetadata.exportedAt,
                firstDeliveredAt: staleDraftMetadata.firstDeliveredAt
            ),
            pinnedDiagnostics: pinnedDiagnostics
        )
        var updatedRow: AppState.NormalizedSessionLifecycleReplayRow?

        let result = await AppState.executeNormalizedSessionLifecycleReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { row in
            updatedRow = row
            return AppState.NormalizedSessionLifecycleReplayWriteSummary(
                updatedCount: 1,
                message: "session_lifecycle_replayed"
            )
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertNotNil(plan.rowToUpdate)
        XCTAssertEqual(plan.idempotentSkippedCount, 0)
        XCTAssertEqual(plan.rowToUpdate?.status, Session.Status.completed.rawValue)
        XCTAssertEqual(plan.rowToUpdate?.pinnedRemoteStatusEvidence, Session.Status.draft.rawValue)
        XCTAssertEqual(result.upsertedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(updatedRow?.propertyID, propertyID)
        XCTAssertEqual(updatedRow?.sessionID, sessionID)
    }

    func testSelectedSessionLifecycleReplayPrefersLiveCompletedStatusOverStaleDraftMetadata() async {
        let staleDraftMetadata = metadata(status: .draft)
        let liveCompletedSession = completedLocalSession()
        let local = AppState.CanonicalReadLocalSnapshot(
            propertyID: propertyID,
            orgID: orgID,
            sessionID: sessionID,
            sessionPropertyID: propertyID,
            sessionStatus: liveCompletedSession.status.rawValue,
            shotCount: staleDraftMetadata.shots.count,
            issueObservationCount: staleDraftMetadata.issues.count,
            guidedCount: staleDraftMetadata.guidedShots.count,
            updatedAt: staleDraftMetadata.endedAt,
            localKnownStateSource: "session.completed_at",
            localPropertyFound: true,
            localSessionFound: true
        )
        let remote = AppState.CanonicalReadRemoteSnapshot(
            properties: remoteProperties(),
            sessions: remoteSessions(status: Session.Status.draft.rawValue),
            shots: [AppState.CanonicalReadRemoteShotRow(id: shotID, sessionID: sessionID, deletedAt: nil)],
            observations: [
                AppState.CanonicalReadRemoteObservationRow(
                    id: issueID,
                    orgID: orgID,
                    propertyID: propertyID,
                    sessionID: sessionID,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
                    deletedAt: nil
                )
            ]
        )
        let diagnostics = AppState.makeCanonicalReadDiagnostics(
            checkedAt: Date(timeIntervalSinceReferenceDate: 10_700),
            activeOrganizationID: orgID,
            local: local,
            remote: remote
        )
        let plan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: staleDraftMetadata,
            localSession: liveCompletedSession,
            remoteSession: remoteLifecycleSession(
                status: Session.Status.draft.rawValue,
                completedAt: staleDraftMetadata.endedAt,
                exportedAt: staleDraftMetadata.exportedAt,
                firstDeliveredAt: staleDraftMetadata.firstDeliveredAt
            ),
            pinnedDiagnostics: diagnostics
        )
        var updatedRow: AppState.NormalizedSessionLifecycleReplayRow?

        let result = await AppState.executeNormalizedSessionLifecycleReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { row in
            updatedRow = row
            return AppState.NormalizedSessionLifecycleReplayWriteSummary(
                updatedCount: 1,
                message: "session_lifecycle_replayed"
            )
        }

        XCTAssertEqual(diagnostics.localSessionStatus, Session.Status.completed.rawValue)
        XCTAssertEqual(diagnostics.remoteSessionStatus, Session.Status.draft.rawValue)
        XCTAssertEqual(diagnostics.statusParity, false)
        XCTAssertTrue(plan.allowed)
        XCTAssertNotNil(plan.rowToUpdate)
        XCTAssertEqual(plan.idempotentSkippedCount, 0)
        XCTAssertEqual(plan.rowToUpdate?.status, Session.Status.completed.rawValue)
        XCTAssertEqual(result.upsertedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(updatedRow?.propertyID, propertyID)
        XCTAssertEqual(updatedRow?.sessionID, sessionID)
        XCTAssertEqual(updatedRow?.status, Session.Status.completed.rawValue)
    }

    func testSelectedSessionLifecycleReplayWrongOrgPropertyOrSessionBlocks() {
        let wrongOrgPlan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(orgID: UUID())
        )
        let wrongPropertyPlan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(propertyID: UUID())
        )
        let wrongSessionPlan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(sessionID: UUID())
        )

        XCTAssertFalse(wrongOrgPlan.allowed)
        XCTAssertFalse(wrongPropertyPlan.allowed)
        XCTAssertFalse(wrongSessionPlan.allowed)
        XCTAssertEqual(wrongOrgPlan.blockedReason, "remote_session_scope_mismatch")
        XCTAssertEqual(wrongPropertyPlan.blockedReason, "remote_session_scope_mismatch")
        XCTAssertEqual(wrongSessionPlan.blockedReason, "remote_session_scope_mismatch")
    }

    func testSelectedSessionLifecycleReplayAllowsStaleRemoteDraftCorrectionWhenDiagnosticsAreClean() async {
        let pinnedDiagnostics = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .divergentConflict,
            recommendation: "local_first_block_canonical_read",
            countParity: true,
            statusParity: false,
            localStatus: Session.Status.completed.rawValue,
            remoteStatus: Session.Status.draft.rawValue
        )
        let plan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(
                status: Session.Status.draft.rawValue,
                updatedAt: Date(timeIntervalSinceReferenceDate: 11_000)
            ),
            pinnedDiagnostics: pinnedDiagnostics
        )
        var updatedRow: AppState.NormalizedSessionLifecycleReplayRow?

        let result = await AppState.executeNormalizedSessionLifecycleReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { row in
            updatedRow = row
            return AppState.NormalizedSessionLifecycleReplayWriteSummary(
                updatedCount: 1,
                message: row.allowsStaleRemoteDraftLifecycleCorrection
                    ? "stale_remote_draft_lifecycle_corrected"
                    : "session_lifecycle_replayed"
            )
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertNotNil(plan.rowToUpdate)
        XCTAssertEqual(plan.remoteNewerSkippedCount, 0)
        XCTAssertEqual(plan.rowToUpdate?.status, Session.Status.completed.rawValue)
        XCTAssertEqual(plan.rowToUpdate?.pinnedRemoteStatusEvidence, Session.Status.draft.rawValue)
        XCTAssertEqual(plan.rowToUpdate?.allowsStaleRemoteDraftLifecycleCorrection, true)
        XCTAssertEqual(updatedRow?.sessionID, sessionID)
        XCTAssertEqual(result.upsertedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.remoteNewerConflictCount, 0)
        XCTAssertEqual(result.message, "stale_remote_draft_lifecycle_corrected")
    }

    func testSelectedSessionLifecycleReplayPreservesOtherNewerRemoteStatuses() async {
        let pinnedDiagnostics = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .divergentConflict,
            recommendation: "local_first_block_canonical_read",
            countParity: true,
            statusParity: false,
            localStatus: Session.Status.completed.rawValue,
            remoteStatus: "in_progress"
        )
        let plan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(
                status: "in_progress",
                updatedAt: Date(timeIntervalSinceReferenceDate: 11_000)
            ),
            pinnedDiagnostics: pinnedDiagnostics
        )
        var updateCalled = false

        let result = await AppState.executeNormalizedSessionLifecycleReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { _ in
            updateCalled = true
            return AppState.NormalizedSessionLifecycleReplayWriteSummary(
                updatedCount: 1,
                message: "session_lifecycle_replayed"
            )
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertNil(plan.rowToUpdate)
        XCTAssertEqual(plan.remoteNewerSkippedCount, 1)
        XCTAssertFalse(updateCalled)
        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.remoteNewerConflictCount, 1)
        XCTAssertEqual(result.message, "newer_remote_session_lifecycle_preserved")
    }

    func testSelectedSessionLifecycleReplayIsIdempotentWhenRemoteAlreadyMatches() async {
        let completedAt = Date(timeIntervalSinceReferenceDate: 10_600)
        let pinnedDiagnostics = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .remoteMatchesLocal,
            recommendation: "local_preferred_remote_verified",
            countParity: true,
            statusParity: true,
            localStatus: Session.Status.completed.rawValue,
            remoteStatus: Session.Status.completed.rawValue
        )
        let plan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(
                status: "completed",
                completedAt: completedAt,
                isSealed: true
            ),
            pinnedDiagnostics: pinnedDiagnostics
        )
        var updateCalled = false

        let result = await AppState.executeNormalizedSessionLifecycleReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { _ in
            updateCalled = true
            return AppState.NormalizedSessionLifecycleReplayWriteSummary(
                updatedCount: 1,
                message: "session_lifecycle_replayed"
            )
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertNil(plan.rowToUpdate)
        XCTAssertFalse(updateCalled)
        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.message, "session_lifecycle_already_current")
    }

    func testSelectedSessionLifecycleReplayWriteTimeNewerRemoteIsPreservedAndCounted() async {
        let plan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(
                status: "draft",
                updatedAt: Date(timeIntervalSinceReferenceDate: 10_100)
            )
        )
        guard let row = plan.rowToUpdate else {
            XCTFail("Expected lifecycle replay row to be planned")
            return
        }
        var supabaseUpdateCalled = false

        let result = await AppState.executeNormalizedSessionLifecycleReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { row in
            if let writePreflight = AppState.makeNormalizedSessionLifecycleReplayWritePreflightResult(
                row: row,
                latestRemoteSession: self.remoteLifecycleSession(
                    status: "draft",
                    updatedAt: Date(timeIntervalSinceReferenceDate: 11_000)
                )
            ) {
                return writePreflight
            }
            supabaseUpdateCalled = true
            return AppState.NormalizedSessionLifecycleReplayWriteSummary(
                updatedCount: 1,
                message: "session_lifecycle_replayed"
            )
        }

        XCTAssertEqual(row.sessionID, sessionID)
        XCTAssertFalse(supabaseUpdateCalled)
        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.remoteNewerConflictCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.message, "newer_remote_session_lifecycle_preserved")
    }

    func testSelectedSessionLifecycleReplayWriteTimeStillDraftAllowsStaleDraftCorrection() async {
        let pinnedDiagnostics = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .divergentConflict,
            recommendation: "local_first_block_canonical_read",
            countParity: true,
            statusParity: false,
            localStatus: Session.Status.completed.rawValue,
            remoteStatus: Session.Status.draft.rawValue
        )
        let plan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(
                status: Session.Status.draft.rawValue,
                updatedAt: Date(timeIntervalSinceReferenceDate: 11_000)
            ),
            pinnedDiagnostics: pinnedDiagnostics
        )
        guard let row = plan.rowToUpdate else {
            XCTFail("Expected stale draft correction row to be planned")
            return
        }
        var supabaseUpdateCalled = false

        let result = await AppState.executeNormalizedSessionLifecycleReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { row in
            if let writePreflight = AppState.makeNormalizedSessionLifecycleReplayWritePreflightResult(
                row: row,
                latestRemoteSession: self.remoteLifecycleSession(
                    status: Session.Status.draft.rawValue,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 12_000)
                )
            ) {
                return writePreflight
            }
            supabaseUpdateCalled = true
            return AppState.NormalizedSessionLifecycleReplayWriteSummary(
                updatedCount: 1,
                message: "stale_remote_draft_lifecycle_corrected"
            )
        }

        XCTAssertTrue(row.allowsStaleRemoteDraftLifecycleCorrection)
        XCTAssertTrue(supabaseUpdateCalled)
        XCTAssertEqual(result.upsertedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.remoteNewerConflictCount, 0)
        XCTAssertEqual(result.message, "stale_remote_draft_lifecycle_corrected")
    }

    func testSelectedSessionLifecycleReplayWriteTimeChangedFromDraftSkipsSafely() async {
        let pinnedDiagnostics = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .divergentConflict,
            recommendation: "local_first_block_canonical_read",
            countParity: true,
            statusParity: false,
            localStatus: Session.Status.completed.rawValue,
            remoteStatus: Session.Status.draft.rawValue
        )
        let plan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(
                status: Session.Status.draft.rawValue,
                updatedAt: Date(timeIntervalSinceReferenceDate: 11_000)
            ),
            pinnedDiagnostics: pinnedDiagnostics
        )
        var supabaseUpdateCalled = false

        let result = await AppState.executeNormalizedSessionLifecycleReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { row in
            if let writePreflight = AppState.makeNormalizedSessionLifecycleReplayWritePreflightResult(
                row: row,
                latestRemoteSession: self.remoteLifecycleSession(
                    status: Session.Status.completed.rawValue,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 12_000)
                )
            ) {
                return writePreflight
            }
            supabaseUpdateCalled = true
            return AppState.NormalizedSessionLifecycleReplayWriteSummary(
                updatedCount: 1,
                message: "unexpected"
            )
        }

        XCTAssertEqual(plan.rowToUpdate?.allowsStaleRemoteDraftLifecycleCorrection, true)
        XCTAssertFalse(supabaseUpdateCalled)
        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.remoteNewerConflictCount, 1)
        XCTAssertEqual(result.message, "remote_session_lifecycle_changed_before_replay")
    }

    func testSelectedSessionLifecycleReplayBlocksStaleDraftCorrectionWhenChildrenOrParentsAreUnclean() async {
        let childMismatchDiagnostics = canonicalDiagnostics(
            remoteObservationCount: 0,
            result: .divergentConflict,
            recommendation: "local_first_block_canonical_read",
            countParity: false,
            statusParity: false,
            localStatus: Session.Status.completed.rawValue,
            remoteStatus: Session.Status.draft.rawValue
        )
        let childMismatchPlan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(
                status: Session.Status.draft.rawValue,
                updatedAt: Date(timeIntervalSinceReferenceDate: 11_000)
            ),
            pinnedDiagnostics: childMismatchDiagnostics
        )

        let parentMismatchDiagnostics = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .divergentConflict,
            recommendation: "local_first_block_canonical_read",
            countParity: true,
            statusParity: false,
            parentOrgConsistent: false,
            localStatus: Session.Status.completed.rawValue,
            remoteStatus: Session.Status.draft.rawValue
        )
        let parentMismatchPlan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(
                status: Session.Status.draft.rawValue,
                updatedAt: Date(timeIntervalSinceReferenceDate: 11_000)
            ),
            pinnedDiagnostics: parentMismatchDiagnostics
        )

        XCTAssertNil(childMismatchPlan.rowToUpdate)
        XCTAssertEqual(childMismatchPlan.remoteNewerSkippedCount, 1)
        XCTAssertNil(parentMismatchPlan.rowToUpdate)
        XCTAssertEqual(parentMismatchPlan.remoteNewerSkippedCount, 1)
    }

    @MainActor
    func testSelectedSessionLifecycleReplayPayloadExcludesSealAndAuditFields() throws {
        let plan = AppState.makeNormalizedSessionLifecycleReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            localSession: completedLocalSession(),
            remoteSession: remoteLifecycleSession(
                status: "draft",
                updatedAt: Date(timeIntervalSinceReferenceDate: 10_100)
            )
        )
        guard let row = plan.rowToUpdate else {
            XCTFail("Expected lifecycle replay row to be planned")
            return
        }

        let keys = try AppState.normalizedSessionLifecycleReplayPayloadKeysTestOnly(row: row)

        XCTAssertTrue(keys.contains("status"))
        XCTAssertTrue(keys.contains("completed_at"))
        XCTAssertFalse(keys.contains("is_sealed"))
        XCTAssertFalse(keys.contains("updated_by"))
        XCTAssertFalse(keys.contains("re_export_expires_at"))
        XCTAssertFalse(keys.contains("title"))
        XCTAssertFalse(keys.contains("capture_profile"))
    }

    @MainActor
    func testSelectedSessionLifecycleReplayPostReplayDiagnosticsStayPinnedAfterSelectionChanges() async throws {
        let fixture = try makeAppFixture(
            environment: selectedSessionReplayEnvironment,
            canonicalReadRemoteSnapshotFetchOverride: { _, propertyID, sessionID in
                self.canonicalRemoteSnapshot(
                    propertyID: propertyID ?? self.propertyID,
                    sessionID: sessionID ?? self.sessionID,
                    status: "draft",
                    shotCount: 1,
                    observationCount: 1
                )
            }
        )
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)
        var diagnosticsOrgID: UUID?
        var diagnosticsPropertyID: UUID?
        var diagnosticsSessionID: UUID?

        let result = await fixture.appState.replaySelectedSessionLifecycleShadowWriteForSelectedSession(
            productionValidationEvidence: passingPackageValidationReport(),
            replayOperation: { _, _, _ in
                await MainActor.run {
                    _ = self.selectDifferentSessionDuringReplay(fixture)
                }
                return AppState.NormalizedBackfillEntityResult(
                    kind: .session,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "session_lifecycle_replayed"
                )
            },
            diagnosticsAfterReplayOperation: { orgID, propertyID, sessionID in
                diagnosticsOrgID = orgID
                diagnosticsPropertyID = propertyID
                diagnosticsSessionID = sessionID
                return self.canonicalDiagnostics(
                    remoteObservationCount: 1,
                    result: .remoteMatchesLocal,
                    recommendation: "remote_candidate_after_session_lifecycle_replay",
                    countParity: true,
                    statusParity: true
                )
            }
        )

        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertTrue(result.allowed)
        XCTAssertEqual(diagnosticsOrgID, orgID)
        XCTAssertEqual(diagnosticsPropertyID, propertyID)
        XCTAssertEqual(diagnosticsSessionID, sessionID)
        XCTAssertEqual(result.diagnosticsAfterReplay?.propertyID, propertyID)
        XCTAssertEqual(result.diagnosticsAfterReplay?.sessionID, sessionID)
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsPropertyID, propertyID)
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsSessionID, sessionID)
    }

    @MainActor
    func testSelectedSessionLifecycleReplayRefreshesStatusParityAfterReplay() async throws {
        var remoteStatus = "draft"
        let fixture = try makeAppFixture(
            environment: selectedSessionReplayEnvironment,
            canonicalReadRemoteSnapshotFetchOverride: { _, propertyID, sessionID in
                self.canonicalRemoteSnapshot(
                    propertyID: propertyID ?? self.propertyID,
                    sessionID: sessionID ?? self.sessionID,
                    status: remoteStatus,
                    shotCount: 1,
                    observationCount: 1
                )
            }
        )
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)
        var replayedOrgID: UUID?
        var replayedPropertyID: UUID?
        var replayedSessionID: UUID?

        let result = await fixture.appState.replaySelectedSessionLifecycleShadowWriteForSelectedSession(
            productionValidationEvidence: passingPackageValidationReport(),
            replayOperation: { orgID, propertyID, sessionID in
                replayedOrgID = orgID
                replayedPropertyID = propertyID
                replayedSessionID = sessionID
                remoteStatus = "completed"
                return AppState.NormalizedBackfillEntityResult(
                    kind: .session,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "session_lifecycle_replayed"
                )
            }
        )

        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertTrue(result.allowed)
        XCTAssertEqual(replayedOrgID, orgID)
        XCTAssertEqual(replayedPropertyID, propertyID)
        XCTAssertEqual(replayedSessionID, sessionID)
        XCTAssertEqual(result.replayResult?.upsertedCount, 1)
        XCTAssertEqual(result.diagnosticsAfterReplay?.statusParity, true)
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsStatusParity, true)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillPlannedSessionUpserts, 1)
        XCTAssertEqual(diagnostics.lastNormalizedBackfillExecutedEntityCount, 1)
    }

    @MainActor
    func testSelectedSessionLifecycleReplayNormalizesPostReplayRemoteNewerWhenSemanticParityIsClean() async throws {
        let fixture = try makeAppFixture(
            environment: selectedSessionReplayProductionValidationEnvironment,
            canonicalReadRemoteSnapshotFetchOverride: { _, propertyID, sessionID in
                self.canonicalRemoteSnapshot(
                    propertyID: propertyID ?? self.propertyID,
                    sessionID: sessionID ?? self.sessionID,
                    status: "completed",
                    shotCount: 1,
                    observationCount: 1
                )
            }
        )
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)

        let result = await fixture.appState.replaySelectedSessionLifecycleShadowWriteForSelectedSession(
            productionValidationEvidence: passingPackageValidationReport(),
            replayOperation: { _, _, _ in
                AppState.NormalizedBackfillEntityResult(
                    kind: .session,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "session_lifecycle_replayed"
                )
            },
            diagnosticsAfterReplayOperation: { _, _, _ in
                self.canonicalDiagnostics(
                    remoteObservationCount: 1,
                    result: .remoteNewerCandidate,
                    recommendation: "manual_review_remote_candidate",
                    countParity: true,
                    statusParity: true,
                    localUpdatedAt: Date(timeIntervalSinceReferenceDate: 10_600),
                    remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 12_000)
                )
            }
        )

        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertTrue(result.allowed)
        XCTAssertEqual(result.diagnosticsAfterReplay?.result, .remoteMatchesLocal)
        XCTAssertEqual(result.diagnosticsAfterReplay?.canonicalRecommendation, "remote_candidate_after_replay_validation")
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsResult, AppState.CanonicalReadDiagnosticResult.remoteMatchesLocal.rawValue)
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsRecommendation, "remote_candidate_after_replay_validation")
        XCTAssertEqual(diagnostics.lastNormalizedBackfillRemoteNewerConflictCount, 0)
        XCTAssertTrue(diagnostics.lastCanonicalReadCandidateAllowed)
        XCTAssertEqual(diagnostics.lastCanonicalReadCandidateBlockedReason, "none")
    }

    @MainActor
    func testSelectedSessionLifecycleReplayDoesNotActivateSwitchReadsOrEnableBroadReads() async throws {
        let fixture = try makeAppFixture(
            environment: selectedSessionReplayEnvironment,
            canonicalReadRemoteSnapshotFetchOverride: { _, propertyID, sessionID in
                self.canonicalRemoteSnapshot(
                    propertyID: propertyID ?? self.propertyID,
                    sessionID: sessionID ?? self.sessionID,
                    status: "draft",
                    shotCount: 1,
                    observationCount: 1
                )
            }
        )
        defer { tearDownAppFixture(fixture) }
        configureSelectedSessionReplayFixture(fixture)

        let result = await fixture.appState.replaySelectedSessionLifecycleShadowWriteForSelectedSession(
            productionValidationEvidence: passingPackageValidationReport(),
            replayOperation: { _, _, _ in
                AppState.NormalizedBackfillEntityResult(
                    kind: .session,
                    attemptedCount: 1,
                    upsertedCount: 1,
                    skippedCount: 0,
                    failedCount: 0,
                    message: "session_lifecycle_replayed"
                )
            }
        )

        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        XCTAssertTrue(result.allowed)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(diagnostics.lastCanonicalReadCandidateProductionWideEnabled)
        XCTAssertEqual(diagnostics.lastCanonicalCandidateActivationActiveSource, "local")
        XCTAssertNotEqual(diagnostics.lastCanonicalCandidateActivationActiveSource, "canonical_candidate")
        XCTAssertTrue(diagnostics.lastCanonicalReadsRemainBlocked)
        XCTAssertTrue(diagnostics.lastNormalizedBackfillProductionBlocked)
        XCTAssertTrue(diagnostics.lastCanonicalCandidateActivationProductionBlocked)
    }

    func testFlaggedLocalObservationReplaysExactlyOneRemoteObservation() async {
        let plan = replayPlan()
        var remoteRows: [AppState.NormalizedObservationReplayRow] = []

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { rows in
            remoteRows.append(contentsOf: rows)
            return rows.count
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertEqual(plan.rowsToUpsert.count, 1)
        XCTAssertEqual(result.upsertedCount, 1)
        XCTAssertEqual(remoteRows.count, 1)
        XCTAssertEqual(remoteRows[0].id, issueID)
        XCTAssertEqual(remoteRows[0].orgID, orgID)
        XCTAssertEqual(remoteRows[0].propertyID, propertyID)
        XCTAssertEqual(remoteRows[0].sessionID, sessionID)
        XCTAssertEqual(remoteRows[0].shotID, shotID)
        XCTAssertEqual(remoteRows[0].category, "flagged_issue")
        XCTAssertEqual(remoteRows[0].status, "active")
    }

    func testInsertOnlyReplayHappyPathInsertsExactlyOneRow() async {
        let plan = replayPlan()

        let replay = await executeInsertOnlyReplay(plan: plan, startingRows: [])

        XCTAssertEqual(replay.result.upsertedCount, 1)
        XCTAssertEqual(replay.result.skippedCount, 0)
        XCTAssertEqual(replay.result.failedCount, 0)
        XCTAssertEqual(replay.result.message, "observation_rows_inserted")
        XCTAssertEqual(replay.remoteRows.count, 1)
        XCTAssertEqual(replay.remoteRows[0].id, issueID)
        XCTAssertEqual(replay.remoteRows[0].orgID, orgID)
        XCTAssertEqual(replay.remoteRows[0].propertyID, propertyID)
        XCTAssertEqual(replay.remoteRows[0].sessionID, sessionID)
    }

    @MainActor
    func testNilSupabaseClientDoesNotReportInsertedObservation() async throws {
        let fixture = try makeAppFixture()
        defer { tearDownAppFixture(fixture) }
        let plan = replayPlan()

        let result = await AppState.executeNormalizedObservationReplayInsertOnlyTestOnly(
            plan: plan,
            targetClassification: .localDev
        ) { rows in
            try await fixture.appState._debugInsertObservationRowsFailClosedForTests(rows)
        }

        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertTrue(result.message.contains("Missing Supabase client"))
    }

    @MainActor
    func testInviteUserToOrganizationMissingClientDoesNotThrowObservationReplayError() async throws {
        let fixture = try makeAppFixture()
        defer { tearDownAppFixture(fixture) }

        do {
            try await fixture.appState.inviteUserToOrganization(
                email: "review@example.com",
                role: "member",
                orgID: orgID
            )
        } catch {
            let nsError = error as NSError
            XCTAssertNotEqual(nsError.domain, "ScoutCapture.ObservationReplay")
            throw error
        }
    }

    func testInsertOnlyDuplicateExactSessionResolvesIdempotentAfterConfirmation() async {
        let plan = replayPlan()
        let existing = AppState.CanonicalReadRemoteObservationRow(
            id: issueID,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
            deletedAt: nil
        )

        let replay = await executeInsertOnlyReplay(plan: plan, startingRows: [existing])

        XCTAssertEqual(replay.result.upsertedCount, 0)
        XCTAssertEqual(replay.result.skippedCount, 1)
        XCTAssertEqual(replay.result.failedCount, 0)
        XCTAssertEqual(replay.result.message, "observation_duplicate_exact_scope_idempotent")
        XCTAssertEqual(replay.remoteRows, [existing])
    }

    func testInsertOnlyDuplicateWrongSessionDoesNotMoveOrUpdateExistingRow() async {
        let plan = replayPlan()
        let existingWrongSession = AppState.CanonicalReadRemoteObservationRow(
            id: issueID,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
            deletedAt: nil
        )

        let replay = await executeInsertOnlyReplay(plan: plan, startingRows: [existingWrongSession])

        XCTAssertEqual(replay.result.upsertedCount, 0)
        XCTAssertEqual(replay.result.skippedCount, 0)
        XCTAssertEqual(replay.result.failedCount, 1)
        XCTAssertEqual(replay.result.message, "remote_observation_parent_mismatch")
        XCTAssertEqual(replay.remoteRows, [existingWrongSession])
    }

    func testInsertOnlyDuplicateWrongPropertyBlocksBeforeMutation() async {
        let plan = replayPlan()
        let existingWrongProperty = AppState.CanonicalReadRemoteObservationRow(
            id: issueID,
            orgID: orgID,
            propertyID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
            deletedAt: nil
        )

        let replay = await executeInsertOnlyReplay(plan: plan, startingRows: [existingWrongProperty])

        XCTAssertEqual(replay.result.upsertedCount, 0)
        XCTAssertEqual(replay.result.skippedCount, 0)
        XCTAssertEqual(replay.result.failedCount, 1)
        XCTAssertEqual(replay.result.message, "remote_observation_parent_mismatch")
        XCTAssertEqual(replay.remoteRows, [existingWrongProperty])
    }

    func testReplayIsIdempotentWhenRemoteObservationExists() async {
        let existing = AppState.CanonicalReadRemoteObservationRow(
            id: issueID,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
            deletedAt: nil
        )
        let plan = replayPlan(remoteObservations: [existing])
        var operationCalled = false

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { rows in
            operationCalled = true
            return rows.count
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertTrue(plan.rowsToUpsert.isEmpty)
        XCTAssertEqual(plan.existingSkippedCount, 1)
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
    }

    func testWrongOrgPropertyOrSessionBlocksObservationReplay() {
        let wrongOrgPlan = AppState.makeNormalizedObservationReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(orgID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!),
            remoteProperties: remoteProperties(),
            remoteSessions: remoteSessions(),
            remoteObservations: []
        )
        let wrongPropertyParentPlan = AppState.makeNormalizedObservationReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            remoteProperties: remoteProperties(),
            remoteSessions: remoteSessions(propertyID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!),
            remoteObservations: []
        )
        let wrongRemoteObservationParentPlan = replayPlan(
            remoteObservations: [
                AppState.CanonicalReadRemoteObservationRow(
                    id: issueID,
                    orgID: orgID,
                    sessionID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
                    deletedAt: nil
                )
            ]
        )

        XCTAssertFalse(wrongOrgPlan.allowed)
        XCTAssertEqual(wrongOrgPlan.blockedReason, "local_snapshot_parent_scope_mismatch")
        XCTAssertFalse(wrongPropertyParentPlan.allowed)
        XCTAssertEqual(wrongPropertyParentPlan.blockedReason, "remote_session_parent_not_verified")
        XCTAssertFalse(wrongRemoteObservationParentPlan.allowed)
        XCTAssertEqual(wrongRemoteObservationParentPlan.blockedReason, "remote_observation_parent_mismatch")
    }

    func testSameObservationIDWrongSessionDiscoveredByIDPreflightBlocksBeforeUpsert() async {
        let scopedPlan = replayPlan(remoteObservations: [])
        let wrongSessionPreflightRows = AppState.mergedObservationReplayPreflightRows(
            scopedSessionRows: [],
            idPreflightRows: [
                AppState.CanonicalReadRemoteObservationRow(
                    id: issueID,
                    orgID: orgID,
                    propertyID: propertyID,
                    sessionID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
                    deletedAt: nil
                )
            ]
        )
        let preflightPlan = AppState.makeNormalizedObservationReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            remoteProperties: remoteProperties(),
            remoteSessions: remoteSessions(),
            remoteObservations: wrongSessionPreflightRows
        )
        var operationCalled = false

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: preflightPlan,
            targetClassification: .approvedStaging
        ) { rows in
            operationCalled = true
            return rows.count
        }

        XCTAssertTrue(scopedPlan.allowed)
        XCTAssertEqual(scopedPlan.rowsToUpsert.count, 1)
        XCTAssertFalse(preflightPlan.allowed)
        XCTAssertEqual(preflightPlan.blockedReason, "remote_observation_parent_mismatch")
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
    }

    func testSameObservationIDWrongPropertyBlocksBeforeUpsert() async {
        let wrongPropertyPreflightRows = AppState.mergedObservationReplayPreflightRows(
            scopedSessionRows: [],
            idPreflightRows: [
                AppState.CanonicalReadRemoteObservationRow(
                    id: issueID,
                    orgID: orgID,
                    propertyID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
                    sessionID: sessionID,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
                    deletedAt: nil
                )
            ]
        )
        let preflightPlan = AppState.makeNormalizedObservationReplayPlan(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            metadata: metadata(),
            remoteProperties: remoteProperties(),
            remoteSessions: remoteSessions(),
            remoteObservations: wrongPropertyPreflightRows
        )
        var operationCalled = false

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: preflightPlan,
            targetClassification: .approvedStaging
        ) { rows in
            operationCalled = true
            return rows.count
        }

        XCTAssertFalse(preflightPlan.allowed)
        XCTAssertEqual(preflightPlan.blockedReason, "remote_observation_parent_mismatch")
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
    }

    func testSoftDeletedExactSessionObservationIsSkippedNotUndeleted() async {
        let softDeletedRemote = AppState.CanonicalReadRemoteObservationRow(
            id: issueID,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
            deletedAt: Date(timeIntervalSinceReferenceDate: 10_300)
        )
        let plan = replayPlan(remoteObservations: [softDeletedRemote])
        var operationCalled = false

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { rows in
            operationCalled = true
            return rows.count
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertTrue(plan.rowsToUpsert.isEmpty)
        XCTAssertEqual(plan.softDeletedSkippedCount, 1)
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.upsertedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.message, "soft_deleted_remote_observations_preserved")
    }

    func testResolvedLocalIssueIsNotReplayed() async {
        let plan = replayPlan(metadata: metadata(issueStatus: "resolved"))
        var operationCalled = false

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { rows in
            operationCalled = true
            return rows.count
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertEqual(plan.attemptedCount, 0)
        XCTAssertTrue(plan.rowsToUpsert.isEmpty)
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.upsertedCount, 0)
    }

    func testNewerRemoteObservationIsPreservedAndSkipped() async {
        let newerRemote = AppState.CanonicalReadRemoteObservationRow(
            id: issueID,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 11_000),
            deletedAt: nil
        )
        let plan = replayPlan(remoteObservations: [newerRemote])
        var operationCalled = false

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: plan,
            targetClassification: .approvedStaging
        ) { rows in
            operationCalled = true
            return rows.count
        }

        XCTAssertTrue(plan.allowed)
        XCTAssertTrue(plan.rowsToUpsert.isEmpty)
        XCTAssertEqual(plan.newerRemoteSkippedCount, 1)
        XCTAssertFalse(operationCalled)
        XCTAssertEqual(result.message, "newer_remote_observations_preserved")
        XCTAssertEqual(result.remoteNewerConflictCount, 1)
    }

    func testCanonicalDiagnosticsAfterReplayCountsLocalAndRemoteObservationsEqually() {
        let local = AppState.CanonicalReadLocalSnapshot(
            propertyID: propertyID,
            orgID: orgID,
            sessionID: sessionID,
            sessionPropertyID: propertyID,
            sessionStatus: "completed",
            shotCount: 10,
            issueObservationCount: 1,
            guidedCount: 0,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            localKnownStateSource: "verified_snapshot_payload",
            localPropertyFound: true,
            localSessionFound: true
        )
        let remote = AppState.CanonicalReadRemoteSnapshot(
            properties: remoteProperties(),
            sessions: remoteSessions(),
            shots: (0..<10).map { _ in
                AppState.CanonicalReadRemoteShotRow(id: UUID(), sessionID: sessionID, deletedAt: nil)
            },
            observations: [
                AppState.CanonicalReadRemoteObservationRow(
                    id: issueID,
                    orgID: orgID,
                    sessionID: sessionID,
                    updatedAt: Date(timeIntervalSinceReferenceDate: 10_250),
                    deletedAt: nil
                )
            ]
        )

        let result = AppState.makeCanonicalReadDiagnostics(
            checkedAt: Date(timeIntervalSinceReferenceDate: 10_700),
            activeOrganizationID: orgID,
            local: local,
            remote: remote
        )

        XCTAssertEqual(result.localIssueObservationCount, 1)
        XCTAssertEqual(result.remoteIssueObservationCount, 1)
        XCTAssertEqual(result.countParity, true)
        XCTAssertEqual(result.result, .remoteMatchesLocal)
    }

    func testCandidateCanProceedPastMissingRemoteChildrenAfterObservationReplay() async {
        let before = canonicalDiagnostics(
            remoteObservationCount: 0,
            result: .divergentConflict,
            recommendation: "local_first_block_canonical_read",
            countParity: false
        )
        let beforeReport = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: before)
        let beforeCandidate = AppState.makeCanonicalReadCandidateDiagnostics(
            configuration: AppState.CanonicalReadCandidateConfiguration(
                enabled: true,
                orgAllowlist: [orgID],
                propertyAllowlist: [propertyID],
                sessionAllowlist: [sessionID],
                parityCompletenessThreshold: 0.95,
                mediaRecoveryConfidenceThreshold: 0.95
            ),
            targetClassification: .approvedStaging,
            canonicalDiagnostics: before,
            parityReport: beforeReport
        )
        let replay = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: replayPlan(),
            targetClassification: .approvedStaging
        ) { rows in rows.count }
        let after = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .remoteMatchesLocal,
            recommendation: "remote_candidate_after_replay_validation",
            countParity: true
        )
        let afterReport = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: after)
        let validation = AppState.validateNormalizedBackfillReplay(
            before: before,
            after: after,
            execution: AppState.NormalizedBackfillReplayExecutionResult(
                allowed: true,
                blockedReason: nil,
                productionBlocked: false,
                attemptedEntityCount: replay.attemptedCount,
                executedEntityCount: replay.upsertedCount,
                skippedEntityCount: replay.skippedCount,
                failedEntityCount: replay.failedCount,
                remoteNewerConflictCount: 0,
                results: [replay],
                noBehaviorChangedText: "No behavior changed: observation replay validation does not switch canonical reads."
            )
        )
        let candidate = AppState.makeCanonicalReadCandidateDiagnostics(
            configuration: AppState.CanonicalReadCandidateConfiguration(
                enabled: true,
                orgAllowlist: [orgID],
                propertyAllowlist: [propertyID],
                sessionAllowlist: [sessionID],
                parityCompletenessThreshold: 0.95,
                mediaRecoveryConfidenceThreshold: 0.95
            ),
            targetClassification: .approvedStaging,
            canonicalDiagnostics: after,
            parityReport: afterReport,
            replayValidation: validation
        )

        XCTAssertEqual(beforeReport.missingChildCount, 1)
        XCTAssertTrue(beforeCandidate.blockedReason?.contains("missing_remote_children") == true)
        XCTAssertEqual(afterReport.missingChildCount, 0)
        XCTAssertFalse(afterReport.taxonomy.contains(.missingRemoteChildren))
        XCTAssertTrue(validation.remainingCanonicalBlockers.isEmpty)
        XCTAssertTrue(candidate.allowed)
        XCTAssertFalse(candidate.productionWideCanonicalReadsEnabled)
    }

    func testLifecycleReplayRemoteNewerWithCleanSemanticParityNormalizesCandidateReady() {
        let remoteNewer = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .remoteNewerCandidate,
            recommendation: "manual_review_remote_candidate",
            countParity: true,
            statusParity: true,
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 12_000)
        )

        let normalized = AppState.normalizeSelectedSessionLifecyclePostReplayRemoteNewerDiagnostics(
            remoteNewer,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            lifecycleReplayExecutedEntityCount: 1,
            lifecycleReplayFailedEntityCount: 0,
            lifecycleReplayRemoteNewerConflictCount: 0
        )
        let report = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: normalized)
        let backfillPlan = AppState.makeNormalizedBackfillReplayPlan(
            canonicalDiagnostics: normalized,
            parityReport: report
        )
        let candidate = AppState.makeCanonicalReadCandidateDiagnostics(
            configuration: AppState.CanonicalReadCandidateConfiguration(
                enabled: true,
                orgAllowlist: [orgID],
                propertyAllowlist: [propertyID],
                sessionAllowlist: [sessionID],
                parityCompletenessThreshold: 0.95,
                mediaRecoveryConfidenceThreshold: 0.95
            ),
            targetClassification: .approvedProductionValidation,
            canonicalDiagnostics: normalized,
            parityReport: report,
            productionValidationEvidenceReady: true
        )
        let overlay = AppState.buildCanonicalCandidateOverlayTestOnly(
            targetClassification: .approvedProductionValidation,
            canonicalDiagnostics: normalized,
            parityReport: report,
            candidateDiagnostics: candidate,
            productionValidationEvidenceReady: true
        )
        let comparison = AppState.makeCanonicalCandidateOverlayComparison(
            canonicalDiagnostics: normalized,
            overlayResult: overlay,
            parityReport: report
        )

        XCTAssertEqual(normalized.result, .remoteMatchesLocal)
        XCTAssertEqual(normalized.canonicalRecommendation, "remote_candidate_after_replay_validation")
        XCTAssertNil(normalized.blockedReason)
        XCTAssertEqual(backfillPlan.remoteNewerConflictCount, 0)
        XCTAssertTrue(candidate.allowed)
        XCTAssertNil(candidate.blockedReason)
        XCTAssertTrue(overlay.allowed)
        XCTAssertEqual(comparison.result, .candidateMatchesLocal)
    }

    func testRemoteNewerWithoutVerifiedLifecycleReplayRemainsBlocked() {
        let remoteNewer = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .remoteNewerCandidate,
            recommendation: "manual_review_remote_candidate",
            countParity: true,
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 12_000)
        )

        let normalized = AppState.normalizeSelectedSessionLifecyclePostReplayRemoteNewerDiagnostics(
            remoteNewer,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            lifecycleReplayExecutedEntityCount: 0,
            lifecycleReplayFailedEntityCount: 0,
            lifecycleReplayRemoteNewerConflictCount: 0
        )
        let report = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: normalized)
        let candidate = AppState.makeCanonicalReadCandidateDiagnostics(
            configuration: AppState.CanonicalReadCandidateConfiguration(
                enabled: true,
                orgAllowlist: [orgID],
                propertyAllowlist: [propertyID],
                sessionAllowlist: [sessionID],
                parityCompletenessThreshold: 0.95,
                mediaRecoveryConfidenceThreshold: 0.95
            ),
            targetClassification: .approvedProductionValidation,
            canonicalDiagnostics: normalized,
            parityReport: report,
            productionValidationEvidenceReady: true
        )

        XCTAssertEqual(normalized.result, .remoteNewerCandidate)
        XCTAssertFalse(candidate.allowed)
        XCTAssertTrue(candidate.blockedReason?.contains("remote_newer_conflict") == true)
    }

    func testLifecycleReplayRemoteNewerWithStatusMismatchRemainsBlocked() {
        let remoteNewer = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .remoteNewerCandidate,
            recommendation: "manual_review_remote_candidate",
            countParity: true,
            statusParity: false,
            localStatus: Session.Status.completed.rawValue,
            remoteStatus: Session.Status.draft.rawValue,
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 12_000)
        )

        let normalized = AppState.normalizeSelectedSessionLifecyclePostReplayRemoteNewerDiagnostics(
            remoteNewer,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            lifecycleReplayExecutedEntityCount: 1,
            lifecycleReplayFailedEntityCount: 0,
            lifecycleReplayRemoteNewerConflictCount: 0
        )

        XCTAssertEqual(normalized.result, .remoteNewerCandidate)
        XCTAssertEqual(normalized.statusParity, false)
    }

    func testLifecycleReplayRemoteNewerWithCountMismatchRemainsBlocked() {
        let remoteNewer = canonicalDiagnostics(
            remoteObservationCount: 2,
            result: .remoteNewerCandidate,
            recommendation: "manual_review_remote_candidate",
            countParity: false,
            localIssueObservationCount: 1,
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 12_000)
        )

        let normalized = AppState.normalizeSelectedSessionLifecyclePostReplayRemoteNewerDiagnostics(
            remoteNewer,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            lifecycleReplayExecutedEntityCount: 1,
            lifecycleReplayFailedEntityCount: 0,
            lifecycleReplayRemoteNewerConflictCount: 0
        )

        XCTAssertEqual(normalized.result, .remoteNewerCandidate)
        XCTAssertEqual(normalized.countParity, false)
    }

    func testLifecycleReplayRemoteNewerWithMissingChildRemainsBlocked() {
        let remoteNewer = canonicalDiagnostics(
            remoteObservationCount: 0,
            result: .remoteNewerCandidate,
            recommendation: "manual_review_remote_candidate",
            countParity: false,
            localIssueObservationCount: 1,
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 12_000)
        )

        let normalized = AppState.normalizeSelectedSessionLifecyclePostReplayRemoteNewerDiagnostics(
            remoteNewer,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            lifecycleReplayExecutedEntityCount: 1,
            lifecycleReplayFailedEntityCount: 0,
            lifecycleReplayRemoteNewerConflictCount: 0
        )
        let report = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: normalized)

        XCTAssertEqual(normalized.result, .remoteNewerCandidate)
        XCTAssertEqual(report.missingChildCount, 1)
    }

    func testLifecycleReplayRemoteNewerWithWrongScopeRemainsBlocked() {
        let wrongPropertyID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let remoteNewer = canonicalDiagnostics(
            remoteObservationCount: 1,
            result: .remoteNewerCandidate,
            recommendation: "manual_review_remote_candidate",
            countParity: true,
            propertyID: wrongPropertyID,
            localUpdatedAt: Date(timeIntervalSinceReferenceDate: 10_600),
            remoteUpdatedAt: Date(timeIntervalSinceReferenceDate: 12_000)
        )

        let normalized = AppState.normalizeSelectedSessionLifecyclePostReplayRemoteNewerDiagnostics(
            remoteNewer,
            orgID: orgID,
            propertyID: propertyID,
            sessionID: sessionID,
            lifecycleReplayExecutedEntityCount: 1,
            lifecycleReplayFailedEntityCount: 0,
            lifecycleReplayRemoteNewerConflictCount: 0
        )

        XCTAssertEqual(normalized.result, .remoteNewerCandidate)
        XCTAssertEqual(normalized.propertyID, wrongPropertyID)
    }

    func testObservationReplayHasNoActivationReadSwitchOrUnrelatedMutationSideEffects() async {
        var unrelatedRows = [
            AppState.CanonicalReadRemoteObservationRow(
                id: UUID(),
                orgID: orgID,
                sessionID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                updatedAt: Date(timeIntervalSinceReferenceDate: 10_000),
                deletedAt: nil
            )
        ]
        let plan = replayPlan()
        let unrelatedBefore = unrelatedRows

        let result = await AppState.executeNormalizedObservationReplayTestOnly(
            plan: plan,
            targetClassification: .approvedProductionValidation
        ) { rows in
            unrelatedRows.append(contentsOf: rows.map {
                AppState.CanonicalReadRemoteObservationRow(
                    id: $0.id,
                    orgID: $0.orgID,
                    sessionID: $0.sessionID,
                    updatedAt: $0.updatedAt,
                    deletedAt: nil
                )
            })
            return rows.count
        }

        XCTAssertEqual(result.kind, .observation)
        XCTAssertEqual(result.upsertedCount, 1)
        XCTAssertEqual(unrelatedRows.first, unrelatedBefore.first)
        XCTAssertTrue(plan.noBehaviorChangedText.contains("does not write shots or media"))
        XCTAssertTrue(plan.noBehaviorChangedText.contains("switch canonical reads"))
        XCTAssertTrue(plan.noBehaviorChangedText.contains("activate candidates"))
    }

    private func canonicalDiagnostics(
        remoteObservationCount: Int,
        result: AppState.CanonicalReadDiagnosticResult,
        recommendation: String,
        countParity: Bool,
        statusParity: Bool = true,
        parentOrgConsistent: Bool = true,
        parentPropertyConsistent: Bool = true,
        localStatus: String = Session.Status.completed.rawValue,
        remoteStatus: String = Session.Status.completed.rawValue,
        propertyID: UUID? = nil,
        sessionID: UUID? = nil,
        orgID: UUID? = nil,
        localShotCount: Int = 10,
        remoteShotCount: Int = 10,
        localIssueObservationCount: Int = 1,
        localUpdatedAt: Date = Date(timeIntervalSinceReferenceDate: 11_900),
        remoteUpdatedAt: Date = Date(timeIntervalSinceReferenceDate: 11_900),
        blockedReason: String? = nil
    ) -> AppState.CanonicalReadDiagnosticsResult {
        let effectivePropertyID = propertyID ?? self.propertyID
        let effectiveSessionID = sessionID ?? self.sessionID
        let effectiveOrgID = orgID ?? self.orgID
        var diagnostics = AppState.CanonicalReadDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 12_000),
            propertyID: effectivePropertyID,
            sessionID: effectiveSessionID,
            activeOrganizationID: effectiveOrgID,
            verifiedOrganizationID: effectiveOrgID,
            result: result,
            remotePropertyFound: true,
            remoteSessionFound: true,
            localPropertyFound: true,
            localSessionFound: true,
            countParity: countParity,
            statusParity: statusParity,
            parentOrgConsistent: parentOrgConsistent,
            parentPropertyConsistent: parentPropertyConsistent,
            localShotCount: localShotCount,
            remoteShotCount: remoteShotCount,
            localIssueObservationCount: localIssueObservationCount,
            remoteIssueObservationCount: remoteObservationCount,
            localGuidedCount: 0,
            remoteGuidedCount: nil,
            localUpdatedAt: localUpdatedAt,
            remoteUpdatedAt: remoteUpdatedAt,
            remoteRevision: 1,
            remoteFreshnessAgeSeconds: 100,
            canonicalRecommendation: recommendation,
            blockedReason: blockedReason ?? (result == .divergentConflict ? "remote_rows_diverge_from_local_counts_or_status" : nil),
            noBehaviorChangedText: "read only"
        )
        diagnostics.localSessionStatus = localStatus
        diagnostics.remoteSessionStatus = remoteStatus
        return diagnostics
    }
}
