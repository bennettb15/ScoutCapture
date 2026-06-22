import XCTest
import CryptoKit
@testable import ScoutCapture

final class Phase2C26OCanonicalCandidateConsumptionTests: XCTestCase {
    private let orgID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let propertyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let snapshotID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct ActivationExecutionFixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let store: LocalStore
        let appState: AppState
        let property: Property
        let session: Session
    }

    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C26O-27N-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults() -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "ScoutCapture-2C26O-27N-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")
        return (suiteName, defaults)
    }

    private func activationExecutionEnvironment() -> [String: String] {
        [
            "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key",
            SupabaseRuntimeConfiguration.canonicalReadCandidateEnabledEnvKey: "true",
            SupabaseRuntimeConfiguration.canonicalReadCandidateOrgAllowlistEnvKey: orgID.uuidString,
            SupabaseRuntimeConfiguration.canonicalReadCandidatePropertyAllowlistEnvKey: propertyID.uuidString,
            SupabaseRuntimeConfiguration.canonicalReadCandidateSessionAllowlistEnvKey: sessionID.uuidString
        ]
    }

    private func productionActivationExecutionEnvironment(
        candidateOrgAllowlist: [UUID]? = nil,
        candidatePropertyAllowlist: [UUID]? = nil,
        candidateSessionAllowlist: [UUID]? = nil
    ) -> [String: String] {
        var environment = activationExecutionEnvironment()
        if let candidateOrgAllowlist {
            environment[SupabaseRuntimeConfiguration.canonicalReadCandidateOrgAllowlistEnvKey] = candidateOrgAllowlist
                .map(\.uuidString)
                .joined(separator: ",")
        }
        if let candidatePropertyAllowlist {
            environment[SupabaseRuntimeConfiguration.canonicalReadCandidatePropertyAllowlistEnvKey] = candidatePropertyAllowlist
                .map(\.uuidString)
                .joined(separator: ",")
        }
        if let candidateSessionAllowlist {
            environment[SupabaseRuntimeConfiguration.canonicalReadCandidateSessionAllowlistEnvKey] = candidateSessionAllowlist
                .map(\.uuidString)
                .joined(separator: ",")
        }
        environment["SCOUTCAPTURE_SUPABASE_URL"] = "https://\(SupabaseRuntimeConfiguration.productionSnapshotValidationProjectRef).supabase.co"
        environment[SupabaseRuntimeConfiguration.productionSnapshotValidationEnvKey] = "true"
        environment[SupabaseRuntimeConfiguration.productionSingleSessionCanonicalActivationEnabledEnvKey] = "true"
        environment[SupabaseRuntimeConfiguration.productionSingleSessionCanonicalActivationOrgAllowlistEnvKey] = orgID.uuidString
        environment[SupabaseRuntimeConfiguration.productionSingleSessionCanonicalActivationPropertyAllowlistEnvKey] = propertyID.uuidString
        environment[SupabaseRuntimeConfiguration.productionSingleSessionCanonicalActivationSessionAllowlistEnvKey] = sessionID.uuidString
        return environment
    }

    @MainActor
    private func makeActivationExecutionFixture(
        environment: [String: String]? = nil,
        activeOrganizationID: UUID? = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        remoteOrgID: UUID? = nil
    ) throws -> ActivationExecutionFixture {
        let defaultsFixture = makeDefaults()
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        _ = try store.createOrganization(Organization(id: orgID, name: "27N Activation Org"))
        let property = try store.createProperty(
            Property(id: propertyID, orgId: orgID, name: "27N Activation Property")
        )
        let session = try store.upsertSession(
            Session(
                id: sessionID,
                propertyID: property.id,
                startedAt: Date(timeIntervalSinceReferenceDate: 7_000),
                status: .completed,
                endedAt: nil,
                exportedAt: nil,
                isSealed: true,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil
            )
        )
        try saveActivationExecutionMetadata(store: store, property: property, session: session)

        let remoteUpdatedAt = [
            property.updatedAt,
            session.startedAt
        ].compactMap { $0 }.max() ?? session.startedAt
        let resolvedRemoteOrgID = remoteOrgID ?? orgID
        let remoteSnapshot = AppState.CanonicalReadRemoteSnapshot(
            properties: [
                AppState.CanonicalReadRemotePropertyRow(
                    id: property.id,
                    orgID: resolvedRemoteOrgID,
                    updatedAt: remoteUpdatedAt,
                    revision: 27,
                    deletedAt: nil
                )
            ],
            sessions: [
                AppState.CanonicalReadRemoteSessionRow(
                    id: session.id,
                    orgID: resolvedRemoteOrgID,
                    propertyID: property.id,
                    status: session.status.rawValue,
                    updatedAt: remoteUpdatedAt,
                    revision: 27,
                    deletedAt: nil
                )
            ],
            shots: [],
            observations: []
        )
        let expectedPropertyID = propertyID
        let expectedSessionID = sessionID
        let appState = AppState(
            localStore: store,
            userDefaults: defaultsFixture.defaults,
            environment: environment ?? activationExecutionEnvironment(),
            sessionSnapshotStorageUploadOverride: { _ in
                XCTFail("27N activation rehearsal must not upload session snapshots")
            },
            sessionSnapshotRowInsertOverride: { _ in
                XCTFail("27N activation rehearsal must not insert session snapshot rows")
            },
            sessionSnapshotMediaDownloadOverride: { _, _ in
                XCTFail("27N activation rehearsal must not download media")
                return Data()
            },
            canonicalReadRemoteSnapshotFetchOverride: { _, requestedPropertyID, requestedSessionID in
                XCTAssertEqual(requestedPropertyID, expectedPropertyID)
                XCTAssertEqual(requestedSessionID, expectedSessionID)
                return remoteSnapshot
            },
            disableCloudBackupForTests: true
        )
        appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(
                    id: orgID,
                    name: "27N Activation Org",
                    role: "owner"
                )
            ],
            activeOrganizationID: activeOrganizationID,
            ready: true
        )
        appState._debugRefreshPropertiesLocallyForTests()
        appState.selectedPropertyID = property.id
        appState.currentSession = session

        return ActivationExecutionFixture(
            suiteName: defaultsFixture.suiteName,
            defaults: defaultsFixture.defaults,
            storageRoot: root,
            store: store,
            appState: appState,
            property: property,
            session: session
        )
    }

    private func tearDownActivationExecutionFixture(_ fixture: ActivationExecutionFixture) {
        fixture.appState.shutdown()
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private func saveActivationExecutionMetadata(
        store: LocalStore,
        property: Property,
        session: Session
    ) throws {
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
            exportedAt: session.exportedAt,
            isSealed: session.isSealed,
            firstDeliveredAt: session.firstDeliveredAt,
            reExportExpiresAt: session.reExportExpiresAt,
            appVersion: "test-app",
            deviceModel: "test-device",
            osVersion: "test-os",
            shots: [],
            issues: [],
            guidedShots: []
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: metadata)
    }

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

    private func singleSessionGatePolicy(
        enabled: Bool = true,
        orgAllowlist: Set<UUID>? = nil,
        propertyAllowlist: Set<UUID>? = nil,
        sessionAllowlist: Set<UUID>? = nil
    ) -> AppState.ProductionSingleSessionActivationGatePolicy {
        AppState.ProductionSingleSessionActivationGatePolicy(
            productionSingleSessionCanonicalActivationEnabled: enabled,
            orgAllowlist: orgAllowlist ?? [orgID],
            propertyAllowlist: propertyAllowlist ?? [propertyID],
            sessionAllowlist: sessionAllowlist ?? [sessionID],
            parityConfidenceThreshold: 0.95,
            replayConfidenceThreshold: 0.95
        )
    }

    private func approvedSingleSessionApproval(
        upload: AppState.SessionSnapshotUploadDiagnostics,
        expiresAt: Date? = Date(timeIntervalSinceReferenceDate: 9_000),
        checkedAt: Date = Date(timeIntervalSinceReferenceDate: 8_000),
        orgID approvedOrgID: UUID? = nil
    ) -> AppState.ProductionCohortOperatorApprovalDiagnostics {
        let controlPlane = AppState.makeProductionCohortControlPlaneDiagnostics(
            upload,
            orgID: approvedOrgID ?? orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            )
        )
        return AppState.makeProductionCohortOperatorApprovalDiagnostics(
            controlPlane,
            requestedState: .approved,
            approvalTimestamp: Date(timeIntervalSinceReferenceDate: 7_900),
            expirationTimestamp: expiresAt,
            checkedAt: checkedAt
        )
    }

    private func passingPackageValidationReport(
        scope: AppState.ProductionCohortApprovalScope? = nil,
        packageBlockers: [String] = [],
        rollbackBlockers: [String] = []
    ) -> AppState.LocalHealthSessionSnapshotPackageValidationReport {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 9_500)
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
            mediaManifestCount: 3,
            mediaRetrievalAcceptedCount: 3,
            mediaRestorationAcceptedCount: 3,
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
            noProductionBehaviorChangedText: "test evidence only; no production behavior changed"
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
            noProductionBehaviorChangedText: "test evidence only; no production behavior changed"
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

    @MainActor
    private func assertPackageReportOverlayBlocksWithExtraCandidateAllowlist(
        environment: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try makeActivationExecutionFixture(environment: environment)
        defer { tearDownActivationExecutionFixture(fixture) }
        let report = passingPackageValidationReport()

        let overlay = await fixture.appState.buildCanonicalCandidateOverlayForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_762),
            productionValidationEvidence: report
        )
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertFalse(overlay.allowed, file: file, line: line)
        XCTAssertNil(overlay.overlay, file: file, line: line)
        XCTAssertTrue(overlay.activeSourceRemainsLocal, file: file, line: line)
        XCTAssertTrue(overlay.rollbackAvailable, file: file, line: line)
        XCTAssertTrue(overlay.productionBlocked, file: file, line: line)
        XCTAssertTrue(
            diagnostics.lastCanonicalReadCandidateBlockedReason.contains(
                "production_canonical_read_candidate_requires_separate_explicit_approval"
            ),
            file: file,
            line: line
        )
        XCTAssertTrue(
            diagnostics.lastCanonicalCandidateOverlayBlockedReason.contains(
                "production_canonical_candidate_overlay_blocked"
            ),
            file: file,
            line: line
        )
        XCTAssertFalse(diagnostics.lastCanonicalCandidateOverlayAllowed, file: file, line: line)
        XCTAssertFalse(diagnostics.lastCanonicalCandidateActivationAllowed, file: file, line: line)
        XCTAssertEqual(diagnostics.lastCanonicalCandidateActivationActiveSource, "local", file: file, line: line)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled, file: file, line: line)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabasePropertyReadEnabled, file: file, line: line)
        XCTAssertEqual(diagnostics.attemptedCount, 0, file: file, line: line)
        XCTAssertFalse(diagnostics.lastStorageUploadCompleted, file: file, line: line)
        XCTAssertFalse(diagnostics.lastRowInsertCompleted, file: file, line: line)
    }

    private func approvedDecisionRecord(
        upload: AppState.SessionSnapshotUploadDiagnostics? = nil,
        checkedAt: Date = Date(timeIntervalSinceReferenceDate: 8_600)
    ) -> AppState.ProductionAllowlistDecisionRecord {
        let upload = upload ?? rolloutReadinessDiagnostics()
        let package = approvedDryRunPackage(upload: upload, checkedAt: checkedAt)
        return AppState.makeProductionAllowlistDecisionRecord(from: package)
    }

    private func approvedDryRunPackage(
        upload: AppState.SessionSnapshotUploadDiagnostics? = nil,
        approvalTimestamp: Date? = Date(timeIntervalSinceReferenceDate: 8_500),
        expirationTimestamp: Date? = Date(timeIntervalSinceReferenceDate: 9_500),
        checkedAt: Date = Date(timeIntervalSinceReferenceDate: 8_600)
    ) -> AppState.ProductionRolloutDryRunPackage {
        let upload = upload ?? rolloutReadinessDiagnostics()
        return AppState.generateProductionRolloutDryRun(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            ),
            approvalTimestamp: approvalTimestamp,
            expirationTimestamp: expirationTimestamp,
            checkedAt: checkedAt
        )
    }

    private func decisionRecord(
        from record: AppState.ProductionAllowlistDecisionRecord,
        sessionID: UUID? = nil,
        approvalState: AppState.ProductionCohortOperatorApprovalState? = nil,
        approvalTimestamp: Date? = nil,
        expirationTimestamp: Date? = nil,
        approvalStale: Bool? = nil,
        rollbackReady: Bool? = nil,
        fallbackRetained: Bool? = nil,
        activationPerformed: Bool? = nil,
        readyForOperatorRecord: Bool? = nil
    ) -> AppState.ProductionAllowlistDecisionRecord {
        AppState.ProductionAllowlistDecisionRecord(
            orgID: record.orgID,
            propertyID: record.propertyID,
            sessionID: sessionID ?? record.sessionID,
            dryRunCheckedAt: record.dryRunCheckedAt,
            approvalState: approvalState ?? record.approvalState,
            approvalTimestamp: approvalTimestamp ?? record.approvalTimestamp,
            expirationTimestamp: expirationTimestamp ?? record.expirationTimestamp,
            approvalStale: approvalStale ?? record.approvalStale,
            blockers: record.blockers,
            parityReady: record.parityReady,
            replayReady: record.replayReady,
            candidateReady: record.candidateReady,
            overlayReady: record.overlayReady,
            rollbackReady: rollbackReady ?? record.rollbackReady,
            fallbackRetained: fallbackRetained ?? record.fallbackRetained,
            activationReadinessOnly: record.activationReadinessOnly,
            productionWideDisabledConfirmation: record.productionWideDisabledConfirmation,
            exactSingleScopeSelected: record.exactSingleScopeSelected,
            activationPerformed: activationPerformed ?? record.activationPerformed,
            activeSource: record.activeSource,
            readyForOperatorRecord: readyForOperatorRecord ?? record.readyForOperatorRecord,
            noBehaviorChangedText: record.noBehaviorChangedText
        )
    }

    private func preflightAudit(
        upload: AppState.SessionSnapshotUploadDiagnostics? = nil,
        record: AppState.ProductionAllowlistDecisionRecord? = nil
    ) -> AppState.ProductionSingleSessionActivationPreflightAudit {
        let upload = upload ?? rolloutReadinessDiagnostics()
        let record = record ?? approvedDecisionRecord(upload: upload)
        let approval = approvedSingleSessionApproval(upload: upload)
        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )
        return AppState.makeProductionSingleSessionActivationPreflightAudit(
            decisionRecord: record,
            gateDiagnostics: gate
        )
    }

    private func activationPreflight(
        from audit: AppState.ProductionSingleSessionActivationPreflightAudit,
        state: AppState.ProductionSingleSessionActivationPreflightState? = nil,
        blockers: [String]? = nil,
        actualActivationBlockers: [String]? = nil,
        fallbackRetained: Bool? = nil,
        rollbackReady: Bool? = nil,
        activationPerformed: Bool? = nil
    ) -> AppState.ProductionSingleSessionActivationPreflightAudit {
        AppState.ProductionSingleSessionActivationPreflightAudit(
            checkedAt: audit.checkedAt,
            state: state ?? audit.state,
            blockers: blockers ?? audit.blockers,
            recordScope: audit.recordScope,
            gateSelectedScope: audit.gateSelectedScope,
            gateApprovedScope: audit.gateApprovedScope,
            decisionRecordReady: audit.decisionRecordReady,
            gateEvidenceReady: audit.gateEvidenceReady,
            actualActivationGateAllowed: audit.actualActivationGateAllowed,
            actualActivationGateBlockedReason: audit.actualActivationGateBlockedReason,
            actualActivationBlockers: actualActivationBlockers ?? audit.actualActivationBlockers,
            productionWideDisabledConfirmation: audit.productionWideDisabledConfirmation,
            fallbackRetained: fallbackRetained ?? audit.fallbackRetained,
            rollbackReady: rollbackReady ?? audit.rollbackReady,
            activationReadinessOnly: audit.activationReadinessOnly,
            activationPerformed: activationPerformed ?? audit.activationPerformed,
            activeSource: audit.activeSource,
            noBehaviorChangedText: audit.noBehaviorChangedText
        )
    }

    private func persistencePreflight(
        from preflight: AppState.ProductionOperatorRolloutRecordPersistencePreflight,
        state: AppState.ProductionOperatorRolloutRecordPersistencePreflightState? = nil,
        blockers: [String]? = nil,
        fallbackRetained: Bool? = nil,
        rollbackReady: Bool? = nil,
        activationPerformed: Bool? = nil,
        persistencePerformed: Bool? = nil
    ) -> AppState.ProductionOperatorRolloutRecordPersistencePreflight {
        AppState.ProductionOperatorRolloutRecordPersistencePreflight(
            checkedAt: preflight.checkedAt,
            state: state ?? preflight.state,
            blockers: blockers ?? preflight.blockers,
            packageScope: preflight.packageScope,
            decisionRecordScope: preflight.decisionRecordScope,
            preflightRecordScope: preflight.preflightRecordScope,
            preflightGateSelectedScope: preflight.preflightGateSelectedScope,
            preflightGateApprovedScope: preflight.preflightGateApprovedScope,
            dryRunState: preflight.dryRunState,
            approvalState: preflight.approvalState,
            approvalTimestamp: preflight.approvalTimestamp,
            expirationTimestamp: preflight.expirationTimestamp,
            approvalFreshnessRepresented: preflight.approvalFreshnessRepresented,
            approvalFresh: preflight.approvalFresh,
            exactSingleScopeSelected: preflight.exactSingleScopeSelected,
            decisionRecordReady: preflight.decisionRecordReady,
            preflightManualReviewOnly: preflight.preflightManualReviewOnly,
            disabledProductionGateBlockerPresent: preflight.disabledProductionGateBlockerPresent,
            productionWideDisabledConfirmation: preflight.productionWideDisabledConfirmation,
            fallbackRetained: fallbackRetained ?? preflight.fallbackRetained,
            rollbackReady: rollbackReady ?? preflight.rollbackReady,
            activeSource: preflight.activeSource,
            activationPerformed: activationPerformed ?? preflight.activationPerformed,
            persistencePerformed: persistencePerformed ?? preflight.persistencePerformed,
            noBehaviorChangedText: preflight.noBehaviorChangedText
        )
    }

    private func disabledProductionGate(
        upload: AppState.SessionSnapshotUploadDiagnostics
    ) -> AppState.ProductionSingleSessionActivationGateDiagnostics {
        AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: approvedSingleSessionApproval(upload: upload),
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )
    }

    private func activationCandidatePackageInputs(
        upload: AppState.SessionSnapshotUploadDiagnostics? = nil
    ) -> (
        upload: AppState.SessionSnapshotUploadDiagnostics,
        package: AppState.ProductionRolloutDryRunPackage,
        record: AppState.ProductionAllowlistDecisionRecord,
        audit: AppState.ProductionSingleSessionActivationPreflightAudit,
        persistence: AppState.ProductionOperatorRolloutRecordPersistencePreflight,
        gate: AppState.ProductionSingleSessionActivationGateDiagnostics,
        activation: AppState.CanonicalCandidateActivationResult
    ) {
        let upload = upload ?? rolloutReadinessDiagnostics()
        let package = approvedDryRunPackage(upload: upload)
        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)
        let gate = disabledProductionGate(upload: upload)
        let audit = AppState.makeProductionSingleSessionActivationPreflightAudit(
            decisionRecord: record,
            gateDiagnostics: gate
        )
        let persistence = AppState.makeProductionOperatorRolloutRecordPersistencePreflight(
            dryRunPackage: package,
            decisionRecord: record,
            activationPreflight: audit
        )
        let activation = AppState.makeCanonicalCandidateActivationResult(
            targetClassification: .approvedProductionValidation,
            diagnostics: upload,
            productionActivationGate: gate
        )
        return (upload, package, record, audit, persistence, gate, activation)
    }

    private func activationCandidatePackage(
        from package: AppState.ProductionSingleSessionActivationCandidatePackage,
        state: AppState.ProductionSingleSessionActivationCandidatePackageState? = nil,
        blockers: [String]? = nil,
        productionWideDisabledConfirmation: Bool? = nil,
        productionSingleSessionGateDisabled: Bool? = nil,
        actualActivationRemainsBlocked: Bool? = nil,
        candidateEvidenceReady: Bool? = nil,
        overlayEvidenceReady: Bool? = nil,
        comparisonEvidenceMatchesLocal: Bool? = nil,
        fallbackRetained: Bool? = nil,
        rollbackReady: Bool? = nil,
        activeSource: AppState.CanonicalCandidateActivationSource? = nil,
        activationPerformed: Bool? = nil,
        persistencePerformed: Bool? = nil
    ) -> AppState.ProductionSingleSessionActivationCandidatePackage {
        AppState.ProductionSingleSessionActivationCandidatePackage(
            checkedAt: package.checkedAt,
            state: state ?? package.state,
            blockers: blockers ?? package.blockers,
            packageScope: package.packageScope,
            decisionRecordScope: package.decisionRecordScope,
            activationPreflightScope: package.activationPreflightScope,
            persistencePreflightScope: package.persistencePreflightScope,
            gateSelectedScope: package.gateSelectedScope,
            gateApprovedScope: package.gateApprovedScope,
            activationResultScope: package.activationResultScope,
            dryRunState: package.dryRunState,
            decisionRecordReady: package.decisionRecordReady,
            activationPreflightManualReviewOnly: package.activationPreflightManualReviewOnly,
            operatorRecordPersistencePreflightReviewOnly: package.operatorRecordPersistencePreflightReviewOnly,
            exactSingleScopeSelected: package.exactSingleScopeSelected,
            productionWideDisabledConfirmation: productionWideDisabledConfirmation ?? package.productionWideDisabledConfirmation,
            productionSingleSessionGateDisabled: productionSingleSessionGateDisabled ?? package.productionSingleSessionGateDisabled,
            actualActivationRemainsBlocked: actualActivationRemainsBlocked ?? package.actualActivationRemainsBlocked,
            actualActivationBlockers: package.actualActivationBlockers,
            candidateEvidenceReady: candidateEvidenceReady ?? package.candidateEvidenceReady,
            overlayEvidenceReady: overlayEvidenceReady ?? package.overlayEvidenceReady,
            comparisonEvidenceMatchesLocal: comparisonEvidenceMatchesLocal ?? package.comparisonEvidenceMatchesLocal,
            fallbackRetained: fallbackRetained ?? package.fallbackRetained,
            rollbackReady: rollbackReady ?? package.rollbackReady,
            activeSource: activeSource ?? package.activeSource,
            activationPerformed: activationPerformed ?? package.activationPerformed,
            persistencePerformed: persistencePerformed ?? package.persistencePerformed,
            noBehaviorChangedText: package.noBehaviorChangedText
        )
    }

    private func activationResult(
        from result: AppState.CanonicalCandidateActivationResult,
        allowed: Bool? = nil,
        activeSource: AppState.CanonicalCandidateActivationSource? = nil,
        productionBlocked: Bool? = nil
    ) -> AppState.CanonicalCandidateActivationResult {
        AppState.CanonicalCandidateActivationResult(
            checkedAt: result.checkedAt,
            allowed: allowed ?? result.allowed,
            blockedReason: (allowed ?? result.allowed) ? nil : result.blockedReason,
            activeSource: activeSource ?? result.activeSource,
            rollbackSource: result.rollbackSource,
            activationScope: result.activationScope,
            propertyID: result.propertyID,
            sessionID: result.sessionID,
            rollbackAvailable: result.rollbackAvailable,
            productionBlocked: productionBlocked ?? result.productionBlocked,
            noBehaviorChangedText: result.noBehaviorChangedText
        )
    }

    private func activationReadinessValidationInputs(
        upload: AppState.SessionSnapshotUploadDiagnostics? = nil
    ) -> (
        upload: AppState.SessionSnapshotUploadDiagnostics,
        candidatePackage: AppState.ProductionSingleSessionActivationCandidatePackage,
        gate: AppState.ProductionSingleSessionActivationGateDiagnostics,
        activation: AppState.CanonicalCandidateActivationResult
    ) {
        let inputs = activationCandidatePackageInputs(upload: upload)
        let candidatePackage = AppState.makeProductionSingleSessionActivationCandidatePackage(
            dryRunPackage: inputs.package,
            decisionRecord: inputs.record,
            activationPreflight: inputs.audit,
            operatorRecordPersistencePreflight: inputs.persistence,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )
        return (inputs.upload, candidatePackage, inputs.gate, inputs.activation)
    }

    private func activationReadinessValidation(
        from validation: AppState.ProductionSingleSessionActivationReadinessValidation,
        state: AppState.ProductionSingleSessionActivationReadinessValidationState? = nil,
        blockers: [String]? = nil,
        activeSource: AppState.CanonicalCandidateActivationSource? = nil,
        activationPerformed: Bool? = nil,
        persistencePerformed: Bool? = nil,
        hydrationPerformed: Bool? = nil,
        fallbackRetained: Bool? = nil,
        rollbackReady: Bool? = nil
    ) -> AppState.ProductionSingleSessionActivationReadinessValidation {
        AppState.ProductionSingleSessionActivationReadinessValidation(
            checkedAt: validation.checkedAt,
            state: state ?? validation.state,
            blockers: blockers ?? validation.blockers,
            candidatePackageScope: validation.candidatePackageScope,
            gateSelectedScope: validation.gateSelectedScope,
            gateApprovedScope: validation.gateApprovedScope,
            activationResultScope: validation.activationResultScope,
            candidatePackageReadyForManualReviewOnly: validation.candidatePackageReadyForManualReviewOnly,
            exactSingleScopeSelected: validation.exactSingleScopeSelected,
            productionWideDisabledConfirmation: validation.productionWideDisabledConfirmation,
            productionSingleSessionGateDisabled: validation.productionSingleSessionGateDisabled,
            actualActivationRemainsBlocked: validation.actualActivationRemainsBlocked,
            actualActivationBlockers: validation.actualActivationBlockers,
            activeSource: activeSource ?? validation.activeSource,
            activationPerformed: activationPerformed ?? validation.activationPerformed,
            persistencePerformed: persistencePerformed ?? validation.persistencePerformed,
            hydrationPerformed: hydrationPerformed ?? validation.hydrationPerformed,
            productionHydrationDisabledConfirmation: validation.productionHydrationDisabledConfirmation,
            fallbackRetained: fallbackRetained ?? validation.fallbackRetained,
            rollbackReady: rollbackReady ?? validation.rollbackReady,
            candidateEvidenceReady: validation.candidateEvidenceReady,
            overlayEvidenceReady: validation.overlayEvidenceReady,
            comparisonEvidenceMatchesLocal: validation.comparisonEvidenceMatchesLocal,
            noBehaviorChangedText: validation.noBehaviorChangedText
        )
    }

    private func restoreDiagnostics(
        result: AppState.SessionSnapshotRestoreDiagnosticOutcome = .restorableMetadataCandidate,
        propertyID: UUID? = nil,
        sessionID: UUID? = nil,
        includeSnapshotID: Bool = true,
        checksumVerified: Bool = true,
        rowObjectVerified: Bool = true,
        parentRemoteVerified: Bool = true,
        snapshotSchemaVersion: Int? = 1,
        freshness: String = "same_as_local"
    ) -> AppState.SessionSnapshotRestoreDiagnosticsResult {
        AppState.SessionSnapshotRestoreDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_400),
            propertyID: propertyID ?? self.propertyID,
            sessionID: sessionID ?? self.sessionID,
            snapshotID: includeSnapshotID ? snapshotID : nil,
            result: result,
            failureReason: result == .restorableMetadataCandidate ? nil : "test_restore_blocker",
            rowFound: true,
            objectReadable: true,
            checksumVerified: checksumVerified,
            byteSizeMatches: checksumVerified,
            rowObjectVerified: rowObjectVerified,
            parentRemoteVerified: parentRemoteVerified,
            snapshotSchemaVersion: snapshotSchemaVersion,
            snapshotCreatedAt: Date(timeIntervalSinceReferenceDate: 9_000),
            snapshotGeneratedAt: Date(timeIntervalSinceReferenceDate: 9_000),
            localSessionExists: true,
            localSessionStatus: "completed",
            localShotCount: 3,
            localIssueCount: 2,
            localGuidedCount: 0,
            snapshotShotCount: 3,
            snapshotIssueCount: 2,
            snapshotGuidedCount: 0,
            snapshotMediaManifestCount: 0,
            snapshotMissingLocalOriginalsCount: 0,
            snapshotSupabaseStorageMetadataCount: 0,
            freshness: freshness,
            mediaRecoveryDiagnostics: .notChecked
        )
    }

    private func hydrationPolicy(
        productionHydrationAllowed: Bool = false,
        hydrationAvailable: Bool = false
    ) -> AppState.SessionSnapshotHydrationPolicyDiagnostics {
        AppState.SessionSnapshotHydrationPolicyDiagnostics(
            hydrationAvailable: hydrationAvailable,
            productionHydrationAllowed: productionHydrationAllowed,
            hydrationMode: productionHydrationAllowed ? "operator_approved_single_session" : "blocked_by_default",
            hydrationScope: productionHydrationAllowed ? "single_selected_session" : "none",
            productionHydrationBlockedReason: productionHydrationAllowed ? nil : "production_hydration_gate_disabled"
        )
    }

    private func hydrationConfirmation(
        restore: AppState.SessionSnapshotRestoreDiagnosticsResult,
        policy: AppState.SessionSnapshotHydrationPolicyDiagnostics,
        propertyIDText: String? = nil,
        sessionIDText: String? = nil,
        snapshotIDText: String? = nil,
        restoreResult: String? = nil,
        canHydrate: Bool? = nil
    ) -> AppState.SessionSnapshotHydrationConfirmation {
        let resolvedCanHydrate = canHydrate ?? policy.hydrationAvailable
        return AppState.SessionSnapshotHydrationConfirmation(
            confirmationRequired: true,
            canHydrate: resolvedCanHydrate,
            blockedReason: resolvedCanHydrate ? nil : (policy.productionHydrationBlockedReason ?? "hydration_execution_blocked"),
            propertyIDText: propertyIDText ?? (restore.propertyID?.uuidString ?? "none"),
            sessionIDText: sessionIDText ?? (restore.sessionID?.uuidString ?? "none"),
            snapshotIDText: snapshotIDText ?? (restore.snapshotID?.uuidString ?? "none"),
            restoreResult: restoreResult ?? restore.result.rawValue,
            shotCountText: restore.snapshotShotCount.map(String.init) ?? "none",
            issueCountText: restore.snapshotIssueCount.map(String.init) ?? "none",
            guidedCountText: restore.snapshotGuidedCount.map(String.init) ?? "none",
            messageText: "hydration confirmation test fixture"
        )
    }

    private func hydrationReadinessPreflightInputs() -> (
        upload: AppState.SessionSnapshotUploadDiagnostics,
        candidatePackage: AppState.ProductionSingleSessionActivationCandidatePackage,
        validation: AppState.ProductionSingleSessionActivationReadinessValidation,
        restore: AppState.SessionSnapshotRestoreDiagnosticsResult,
        policy: AppState.SessionSnapshotHydrationPolicyDiagnostics,
        confirmation: AppState.SessionSnapshotHydrationConfirmation
    ) {
        let activationInputs = activationReadinessValidationInputs()
        let validation = AppState.makeProductionSingleSessionActivationReadinessValidation(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_300),
            candidatePackage: activationInputs.candidatePackage,
            gateDiagnostics: activationInputs.gate,
            activationResult: activationInputs.activation
        )
        let restore = restoreDiagnostics()
        let policy = hydrationPolicy()
        let confirmation = hydrationConfirmation(restore: restore, policy: policy)
        return (activationInputs.upload, activationInputs.candidatePackage, validation, restore, policy, confirmation)
    }

    private func hydrationReadinessPreflight(
        state: AppState.ProductionSingleSessionHydrationReadinessPreflightState? = nil,
        blockers: [String]? = nil,
        fallbackRetained: Bool? = nil
    ) -> AppState.ProductionSingleSessionHydrationReadinessPreflight {
        let inputs = hydrationReadinessPreflightInputs()
        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: inputs.confirmation
        )
        return AppState.ProductionSingleSessionHydrationReadinessPreflight(
            checkedAt: preflight.checkedAt,
            state: state ?? preflight.state,
            blockers: blockers ?? preflight.blockers,
            blockedConditions: preflight.blockedConditions,
            activationReadinessScope: preflight.activationReadinessScope,
            candidatePackageScope: preflight.candidatePackageScope,
            restoreDiagnosticsScope: preflight.restoreDiagnosticsScope,
            activationReadinessReviewOnly: preflight.activationReadinessReviewOnly,
            exactSingleScopeSelected: preflight.exactSingleScopeSelected,
            restoreDiagnosticsScopeMatchesPackage: preflight.restoreDiagnosticsScopeMatchesPackage,
            hydrationConfirmationMatchesScope: preflight.hydrationConfirmationMatchesScope,
            restoreResult: preflight.restoreResult,
            snapshotIDPresent: preflight.snapshotIDPresent,
            checksumVerified: preflight.checksumVerified,
            rowObjectVerified: preflight.rowObjectVerified,
            parentRemoteVerified: preflight.parentRemoteVerified,
            snapshotSchemaSupported: preflight.snapshotSchemaSupported,
            freshnessNotLocalNewer: preflight.freshnessNotLocalNewer,
            hydrationConfirmationRequired: preflight.hydrationConfirmationRequired,
            productionHydrationDisabledNonWriting: preflight.productionHydrationDisabledNonWriting,
            productionHydrationBlockedReason: preflight.productionHydrationBlockedReason,
            hydrationExecutionBlocked: preflight.hydrationExecutionBlocked,
            hydrationPerformed: preflight.hydrationPerformed,
            activeSource: preflight.activeSource,
            activationPerformed: preflight.activationPerformed,
            persistencePerformed: preflight.persistencePerformed,
            fallbackRetained: fallbackRetained ?? preflight.fallbackRetained,
            rollbackReady: preflight.rollbackReady,
            noBehaviorChangedText: preflight.noBehaviorChangedText
        )
    }

    private func fixtureMetadataEvidence(
        fingerprint: String,
        scope: AppState.ProductionCohortApprovalScope? = nil,
        shotCount: Int = 3,
        issueCount: Int = 2,
        guidedCount: Int = 0,
        fallbackRetained: Bool = true
    ) -> AppState.ProductionSingleSessionHydrationFixtureMetadataEvidence {
        AppState.ProductionSingleSessionHydrationFixtureMetadataEvidence(
            scope: scope ?? AppState.ProductionCohortApprovalScope(
                orgID: orgID,
                propertyID: propertyID,
                sessionID: sessionID
            ),
            metadataFingerprint: fingerprint,
            shotCount: shotCount,
            issueCount: issueCount,
            guidedCount: guidedCount,
            fallbackRetained: fallbackRetained
        )
    }

    private func rehearsalOperationEvidence(
        operationName: String,
        scope: AppState.ProductionCohortApprovalScope? = nil,
        succeeded: Bool = true,
        executedInIsolatedFixture: Bool = true,
        productionTarget: Bool = false,
        productionReadsEnabled: Bool = false,
        remoteStateWriteAttempted: Bool = false,
        realLocalUserStateWriteAttempted: Bool = false,
        fingerprint: String? = "post-fixture",
        shotCount: Int? = 3,
        issueCount: Int? = 2,
        guidedCount: Int? = 0,
        failureReason: String? = nil
    ) -> AppState.ProductionSingleSessionHydrationRehearsalOperationEvidence {
        AppState.ProductionSingleSessionHydrationRehearsalOperationEvidence(
            operationName: operationName,
            targetScope: scope ?? AppState.ProductionCohortApprovalScope(
                orgID: orgID,
                propertyID: propertyID,
                sessionID: sessionID
            ),
            succeeded: succeeded,
            executedInIsolatedFixture: executedInIsolatedFixture,
            productionTarget: productionTarget,
            productionReadsEnabled: productionReadsEnabled,
            remoteStateWriteAttempted: remoteStateWriteAttempted,
            realLocalUserStateWriteAttempted: realLocalUserStateWriteAttempted,
            metadataFingerprint: fingerprint,
            shotCount: shotCount,
            issueCount: issueCount,
            guidedCount: guidedCount,
            failureReason: failureReason
        )
    }

    private func hydrationExecutionRehearsalInputs() -> (
        preflight: AppState.ProductionSingleSessionHydrationReadinessPreflight,
        restore: AppState.SessionSnapshotRestoreDiagnosticsResult,
        policy: AppState.SessionSnapshotHydrationPolicyDiagnostics,
        preFixture: AppState.ProductionSingleSessionHydrationFixtureMetadataEvidence,
        hydrationOperation: AppState.ProductionSingleSessionHydrationRehearsalOperationEvidence,
        postFixture: AppState.ProductionSingleSessionHydrationFixtureMetadataEvidence,
        rollbackOperation: AppState.ProductionSingleSessionHydrationRehearsalOperationEvidence,
        restoredFixture: AppState.ProductionSingleSessionHydrationFixtureMetadataEvidence
    ) {
        let inputs = hydrationReadinessPreflightInputs()
        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: inputs.confirmation
        )
        let preFixture = fixtureMetadataEvidence(
            fingerprint: "pre-fixture",
            shotCount: 1,
            issueCount: 0,
            guidedCount: 0
        )
        let postFixture = fixtureMetadataEvidence(fingerprint: "post-fixture")
        let hydrationOperation = rehearsalOperationEvidence(operationName: "fixture_hydration")
        let rollbackOperation = rehearsalOperationEvidence(
            operationName: "fixture_rollback",
            fingerprint: "pre-fixture",
            shotCount: 1,
            issueCount: 0,
            guidedCount: 0
        )
        let restoredFixture = fixtureMetadataEvidence(
            fingerprint: "pre-fixture",
            shotCount: 1,
            issueCount: 0,
            guidedCount: 0
        )
        return (preflight, inputs.restore, inputs.policy, preFixture, hydrationOperation, postFixture, rollbackOperation, restoredFixture)
    }

    private func hydrationExecutionRehearsal() -> AppState.ProductionSingleSessionHydrationExecutionRehearsal {
        let inputs = hydrationExecutionRehearsalInputs()
        return AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )
    }

    private func mediaRestorationItem(
        id: UUID = UUID(),
        filename: String,
        data: Data?,
        expectedData: Data? = nil,
        failureReason: String? = nil
    ) -> AppState.ProductionSingleSessionMediaRestorationItem {
        AppState.ProductionSingleSessionMediaRestorationItem(
            id: id,
            originalFilename: filename,
            payloadData: data,
            expectedChecksumSHA256: (expectedData ?? data).map(sha256Hex),
            failureReason: failureReason
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

    @MainActor
    func testNonProductionActivationExecutionRehearsalActivatesAndRollsBackSelectedSession() async throws {
        let fixture = try makeActivationExecutionFixture()
        defer { tearDownActivationExecutionFixture(fixture) }
        let metadataBefore = try fixture.store.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertEqual(fixture.appState.supabaseConfiguration.targetClassification, .localDev)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabasePropertyReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.mediaSupabaseUploadEnabled)

        let overlay = await fixture.appState.buildCanonicalCandidateOverlayForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 7_100)
        )
        XCTAssertTrue(overlay.allowed)
        XCTAssertEqual(overlay.overlay?.organizationID, orgID)
        XCTAssertEqual(overlay.overlay?.propertyID, propertyID)
        XCTAssertEqual(overlay.overlay?.sessionID, sessionID)
        XCTAssertEqual(overlay.overlay?.activeSource, "local")
        XCTAssertEqual(overlay.overlay?.fallbackSource, "local")
        XCTAssertTrue(overlay.localFallbackRetained)
        XCTAssertTrue(overlay.rollbackAvailable)
        XCTAssertTrue(overlay.productionBlocked)

        let activation = fixture.appState.activateCanonicalCandidateForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 7_200)
        )
        let activatedDiagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertTrue(activation.allowed)
        XCTAssertEqual(activation.activeSource, .canonicalCandidate)
        XCTAssertEqual(activation.rollbackSource, .local)
        XCTAssertEqual(activation.propertyID, propertyID)
        XCTAssertEqual(activation.sessionID, sessionID)
        XCTAssertTrue(activation.rollbackAvailable)
        XCTAssertTrue(activation.productionBlocked)
        XCTAssertEqual(activatedDiagnostics.lastCanonicalCandidateActivationActiveSource, "canonical_candidate")
        XCTAssertEqual(activatedDiagnostics.lastCanonicalCandidateActivationRollbackSource, "local")
        XCTAssertEqual(activatedDiagnostics.lastCanonicalCandidateActivationScope, "selected_session_only")
        XCTAssertEqual(activatedDiagnostics.lastCanonicalCandidateActivationPropertyID, propertyID)
        XCTAssertEqual(activatedDiagnostics.lastCanonicalCandidateActivationSessionID, sessionID)
        XCTAssertTrue(activatedDiagnostics.lastCanonicalReadCandidateLocalFallbackAvailable)
        XCTAssertTrue(activatedDiagnostics.lastCanonicalCandidateActivationRollbackAvailable)
        XCTAssertTrue(activatedDiagnostics.lastCanonicalCandidateActivationProductionBlocked)
        XCTAssertNotNil(activatedDiagnostics.lastCanonicalCandidateActivationLastActivatedAt)
        XCTAssertNil(activatedDiagnostics.lastHydrationAt)
        XCTAssertFalse(activatedDiagnostics.lastHydrationAllowed)
        XCTAssertNil(activatedDiagnostics.lastMediaRetrievalAt)
        XCTAssertFalse(activatedDiagnostics.lastMediaRetrievalAllowed)
        XCTAssertEqual(activatedDiagnostics.lastMediaRetrievalAttemptedCount, 0)
        XCTAssertEqual(activatedDiagnostics.attemptedCount, 0)
        XCTAssertFalse(activatedDiagnostics.lastStorageUploadCompleted)
        XCTAssertFalse(activatedDiagnostics.lastRowInsertCompleted)

        let rollback = fixture.appState.rollbackCanonicalCandidateToLocalSource(
            checkedAt: Date(timeIntervalSinceReferenceDate: 7_300)
        )
        let rolledBackDiagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        let metadataAfter = try fixture.store.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )

        XCTAssertTrue(rollback.allowed)
        XCTAssertEqual(rollback.activeSource, .local)
        XCTAssertEqual(rollback.rollbackSource, .local)
        XCTAssertEqual(rollback.propertyID, propertyID)
        XCTAssertEqual(rollback.sessionID, sessionID)
        XCTAssertTrue(rollback.rollbackAvailable)
        XCTAssertTrue(rollback.productionBlocked)
        XCTAssertEqual(rolledBackDiagnostics.lastCanonicalCandidateActivationActiveSource, "local")
        XCTAssertEqual(rolledBackDiagnostics.lastCanonicalCandidateActivationRollbackSource, "local")
        XCTAssertEqual(rolledBackDiagnostics.lastCanonicalCandidateActivationScope, "selected_session_only")
        XCTAssertEqual(rolledBackDiagnostics.lastCanonicalCandidateActivationPropertyID, propertyID)
        XCTAssertEqual(rolledBackDiagnostics.lastCanonicalCandidateActivationSessionID, sessionID)
        XCTAssertTrue(rolledBackDiagnostics.lastCanonicalReadCandidateLocalFallbackAvailable)
        XCTAssertTrue(rolledBackDiagnostics.lastCanonicalCandidateActivationRollbackAvailable)
        XCTAssertTrue(rolledBackDiagnostics.lastCanonicalCandidateActivationProductionBlocked)
        XCTAssertNotNil(rolledBackDiagnostics.lastCanonicalCandidateActivationLastActivatedAt)
        XCTAssertNotNil(rolledBackDiagnostics.lastCanonicalCandidateActivationLastRolledBackAt)
        XCTAssertNil(rolledBackDiagnostics.lastHydrationAt)
        XCTAssertFalse(rolledBackDiagnostics.lastHydrationAllowed)
        XCTAssertNil(rolledBackDiagnostics.lastMediaRetrievalAt)
        XCTAssertFalse(rolledBackDiagnostics.lastMediaRetrievalAllowed)
        XCTAssertEqual(rolledBackDiagnostics.lastMediaRetrievalAttemptedCount, 0)
        XCTAssertEqual(rolledBackDiagnostics.attemptedCount, 0)
        XCTAssertFalse(rolledBackDiagnostics.lastStorageUploadCompleted)
        XCTAssertFalse(rolledBackDiagnostics.lastRowInsertCompleted)
        XCTAssertEqual(metadataAfter.orgID, metadataBefore.orgID)
        XCTAssertEqual(metadataAfter.propertyID, metadataBefore.propertyID)
        XCTAssertEqual(metadataAfter.sessionID, metadataBefore.sessionID)
        XCTAssertEqual(metadataAfter.status, metadataBefore.status)
        XCTAssertEqual(metadataAfter.shots.count, metadataBefore.shots.count)
        XCTAssertEqual(metadataAfter.issues.count, metadataBefore.issues.count)
        XCTAssertEqual(metadataAfter.guidedShots.count, metadataBefore.guidedShots.count)
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

    func testProductionRolloutReportAndDryRunDeriveSelectedOrgFromVerifiedDiagnostics() {
        var upload = rolloutReadinessDiagnostics()
        upload.lastCanonicalReadDiagnosticsVerifiedOrgID = orgID

        let package = AppState.generateProductionRolloutDryRun(upload)
        let dryRunReport = AppState.productionRolloutDryRunReportText(package)
        let rolloutReport = AppState.canonicalReadRolloutReportText(upload)

        XCTAssertEqual(package.cohortControlPlane.cohort.orgID, orgID)
        XCTAssertFalse(package.blockers.contains("org_id_required"))
        XCTAssertTrue(dryRunReport.contains("- selected_org_id: \(orgID.uuidString)"))
        XCTAssertTrue(rolloutReport.contains("- selected_org_id: \(orgID.uuidString)"))
        XCTAssertTrue(rolloutReport.contains("- approved org/property/session: org=\(orgID.uuidString)"))
    }

    func testProductionRolloutReportAndDryRunKeepOrgNoneWhenParentConsistencyMissing() {
        var upload = rolloutReadinessDiagnostics()
        upload.lastCanonicalReadDiagnosticsVerifiedOrgID = orgID
        upload.lastCanonicalReadDiagnosticsParentOrgConsistent = nil

        let package = AppState.generateProductionRolloutDryRun(upload)
        let report = AppState.productionRolloutDryRunReportText(package)

        XCTAssertNil(package.cohortControlPlane.cohort.orgID)
        XCTAssertTrue(package.blockers.contains("org_id_required"))
        XCTAssertTrue(report.contains("- selected_org_id: none"))
    }

    func testProductionRolloutReportAndDryRunKeepOrgNoneWhenParentEvidenceConflicts() {
        var upload = rolloutReadinessDiagnostics()
        upload.lastCanonicalReadDiagnosticsVerifiedOrgID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        upload.lastCanonicalReadDiagnosticsParentOrgConsistent = false

        let package = AppState.generateProductionRolloutDryRun(upload)
        let rolloutReport = AppState.canonicalReadRolloutReportText(upload)

        XCTAssertNil(package.cohortControlPlane.cohort.orgID)
        XCTAssertTrue(package.blockers.contains("org_id_required"))
        XCTAssertTrue(rolloutReport.contains("- selected_org_id: none"))
        XCTAssertTrue(rolloutReport.contains("org_id_required"))
    }

    func testProductionRolloutReportSelectedOrgDerivationDoesNotLoosenActivationGateSafety() {
        var upload = rolloutReadinessDiagnostics()
        upload.lastCanonicalReadDiagnosticsVerifiedOrgID = orgID

        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: nil,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload,
            selectedOrganizationID: orgID
        )
        let activation = AppState.makeCanonicalCandidateActivationResult(
            targetClassification: .approvedProductionValidation,
            diagnostics: upload,
            productionActivationGate: gate
        )

        XCTAssertFalse(gate.gateAllowed)
        XCTAssertTrue(gate.gateBlockedReason?.contains("operator_approval_missing") == true)
        XCTAssertTrue(gate.gateBlockedReason?.contains("production_single_session_canonical_activation_disabled") == true)
        XCTAssertFalse(activation.allowed)
        XCTAssertEqual(activation.activeSource, .local)
        XCTAssertTrue(activation.productionBlocked)
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

    func testProductionAllowlistDecisionRecordBuildsFromDryRunOnlyAndDoesNotActivate() {
        let upload = rolloutReadinessDiagnostics()
        let checkedAt = Date(timeIntervalSinceReferenceDate: 8_100)
        let package = AppState.generateProductionRolloutDryRun(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            ),
            approvalTimestamp: Date(timeIntervalSinceReferenceDate: 8_000),
            expirationTimestamp: Date(timeIntervalSinceReferenceDate: 9_000),
            checkedAt: checkedAt
        )

        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)

        XCTAssertEqual(record.orgID, orgID)
        XCTAssertEqual(record.propertyID, propertyID)
        XCTAssertEqual(record.sessionID, sessionID)
        XCTAssertEqual(record.dryRunCheckedAt, checkedAt)
        XCTAssertEqual(record.approvalState, .approved)
        XCTAssertTrue(record.exactSingleScopeSelected)
        XCTAssertTrue(record.parityReady)
        XCTAssertTrue(record.replayReady)
        XCTAssertTrue(record.candidateReady)
        XCTAssertTrue(record.overlayReady)
        XCTAssertTrue(record.rollbackReady)
        XCTAssertTrue(record.fallbackRetained)
        XCTAssertTrue(record.productionWideDisabledConfirmation)
        XCTAssertTrue(record.activationReadinessOnly)
        XCTAssertFalse(record.activationPerformed)
        XCTAssertEqual(record.activeSource, .local)
        XCTAssertTrue(record.readyForOperatorRecord)
    }

    func testProductionAllowlistDecisionRecordRequiresExactSingleScope() {
        let package = AppState.generateProductionRolloutDryRun(
            AppState.SessionSnapshotUploadDiagnostics()
        )

        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)

        XCTAssertFalse(record.exactSingleScopeSelected)
        XCTAssertFalse(record.readyForOperatorRecord)
        XCTAssertTrue(record.blockers.contains("org_id_required"))
        XCTAssertTrue(record.blockers.contains("property_id_required"))
        XCTAssertTrue(record.blockers.contains("session_id_required"))
        XCTAssertTrue(record.blockers.contains("exact_single_org_property_session_scope_required"))
    }

    func testProductionAllowlistDecisionRecordPreservesExpiredApprovalAndBlocksReadiness() {
        let upload = rolloutReadinessDiagnostics()
        let package = AppState.generateProductionRolloutDryRun(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            ),
            approvalTimestamp: Date(timeIntervalSinceReferenceDate: 8_200),
            expirationTimestamp: Date(timeIntervalSinceReferenceDate: 8_300),
            checkedAt: Date(timeIntervalSinceReferenceDate: 8_400)
        )

        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)

        XCTAssertEqual(record.approvalState, .expired)
        XCTAssertTrue(record.approvalStale)
        XCTAssertFalse(record.readyForOperatorRecord)
        XCTAssertTrue(record.blockers.contains("operator_approval_expired"))
    }

    func testProductionAllowlistDecisionRecordPreservesUnresolvedBlockers() {
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
        let package = AppState.generateProductionRolloutDryRun(upload, orgID: orgID)

        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)

        XCTAssertFalse(record.readyForOperatorRecord)
        XCTAssertTrue(record.blockers.contains("unresolved_missing_remote_children"))
        XCTAssertTrue(record.blockers.contains("unresolved_rollout_blockers") || record.blockers.contains("parity_or_replay_not_verified"))
    }

    func testProductionAllowlistDecisionRecordBlocksWhenProductionWideReadsAreEnabled() {
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

        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)

        XCTAssertFalse(record.productionWideDisabledConfirmation)
        XCTAssertFalse(record.readyForOperatorRecord)
        XCTAssertTrue(record.blockers.contains("production_wide_canonical_reads_not_disabled"))
    }

    func testProductionAllowlistDecisionRecordRequiresLocalICloudFallbackRetained() {
        var upload = rolloutReadinessDiagnostics()
        upload.lastCanonicalReadCandidateLocalFallbackAvailable = false
        let package = AppState.generateProductionRolloutDryRun(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            )
        )

        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)

        XCTAssertFalse(record.fallbackRetained)
        XCTAssertFalse(record.readyForOperatorRecord)
        XCTAssertTrue(record.blockers.contains("local_fallback_unavailable"))
    }

    func testProductionAllowlistDecisionRecordReportIsCopyReadyAndNonActivating() {
        let upload = rolloutReadinessDiagnostics()
        let package = AppState.generateProductionRolloutDryRun(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            ),
            approvalTimestamp: Date(timeIntervalSinceReferenceDate: 8_500),
            expirationTimestamp: Date(timeIntervalSinceReferenceDate: 9_500),
            checkedAt: Date(timeIntervalSinceReferenceDate: 8_600)
        )
        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)

        let text = AppState.productionAllowlistDecisionRecordReportText(record)

        XCTAssertTrue(text.contains("Production Allowlist Decision Record"))
        XCTAssertTrue(text.contains("- org_id: \(orgID.uuidString)"))
        XCTAssertTrue(text.contains("- property_id: \(propertyID.uuidString)"))
        XCTAssertTrue(text.contains("- session_id: \(sessionID.uuidString)"))
        XCTAssertTrue(text.contains("- active_source: local"))
        XCTAssertTrue(text.contains("- activation_performed: false"))
        XCTAssertTrue(text.contains("- ready_for_operator_record: true"))
        XCTAssertTrue(text.contains("does not enable production canonical reads"))
        XCTAssertTrue(text.contains("enable production-wide remote reads"))
        XCTAssertTrue(text.contains("production writes"))
        XCTAssertTrue(text.contains("write local or remote state"))
        XCTAssertTrue(text.contains("activate candidates"))
        XCTAssertTrue(text.contains("activate overlays"))
        XCTAssertTrue(text.contains("remove local/iCloud fallback"))
        XCTAssertTrue(text.contains("change export, seal, sync, media, or iCloud behavior"))
        XCTAssertTrue(text.contains("change schema"))
    }

    func testProductionSingleSessionActivationPreflightAuditReadyForManualReviewOnly() {
        let upload = rolloutReadinessDiagnostics()
        let record = approvedDecisionRecord(upload: upload)
        let approval = approvedSingleSessionApproval(upload: upload)
        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        let audit = AppState.makeProductionSingleSessionActivationPreflightAudit(
            checkedAt: Date(timeIntervalSinceReferenceDate: 8_700),
            decisionRecord: record,
            gateDiagnostics: gate
        )

        XCTAssertEqual(audit.state, .readyForManualReviewOnly)
        XCTAssertTrue(audit.blockers.isEmpty)
        XCTAssertTrue(audit.decisionRecordReady)
        XCTAssertTrue(audit.gateEvidenceReady)
        XCTAssertFalse(audit.actualActivationGateAllowed)
        XCTAssertTrue(audit.actualActivationGateBlockedReason?.contains("production_single_session_canonical_activation_disabled") == true)
        XCTAssertTrue(audit.actualActivationBlockers.contains("production_single_session_canonical_activation_disabled"))
        XCTAssertTrue(audit.productionWideDisabledConfirmation)
        XCTAssertTrue(audit.fallbackRetained)
        XCTAssertTrue(audit.rollbackReady)
        XCTAssertTrue(audit.activationReadinessOnly)
        XCTAssertFalse(audit.activationPerformed)
        XCTAssertEqual(audit.activeSource, .local)
    }

    func testProductionSingleSessionActivationPreflightAuditDisabledGateBlocksActualActivation() {
        let upload = rolloutReadinessDiagnostics()
        let record = approvedDecisionRecord(upload: upload)
        let approval = approvedSingleSessionApproval(upload: upload)
        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        let audit = AppState.makeProductionSingleSessionActivationPreflightAudit(
            decisionRecord: record,
            gateDiagnostics: gate
        )
        let activation = AppState.makeCanonicalCandidateActivationResult(
            targetClassification: .approvedProductionValidation,
            diagnostics: upload,
            productionActivationGate: gate
        )

        XCTAssertEqual(audit.state, .readyForManualReviewOnly)
        XCTAssertFalse(audit.actualActivationGateAllowed)
        XCTAssertTrue(audit.actualActivationBlockers.contains("production_single_session_canonical_activation_disabled"))
        XCTAssertFalse(activation.allowed)
        XCTAssertTrue(activation.blockedReason?.contains("production_canonical_candidate_activation_blocked") == true)
    }

    func testProductionSingleSessionActivationPreflightAuditExpiredApprovalBlocks() {
        let upload = rolloutReadinessDiagnostics()
        let package = AppState.generateProductionRolloutDryRun(
            upload,
            orgID: orgID,
            policy: cohortPolicy(
                requestedStage: .singleSessionActivation,
                approvalState: .approved
            ),
            approvalTimestamp: Date(timeIntervalSinceReferenceDate: 8_200),
            expirationTimestamp: Date(timeIntervalSinceReferenceDate: 8_300),
            checkedAt: Date(timeIntervalSinceReferenceDate: 8_400)
        )
        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)
        let approval = approvedSingleSessionApproval(
            upload: upload,
            expiresAt: Date(timeIntervalSinceReferenceDate: 8_300),
            checkedAt: Date(timeIntervalSinceReferenceDate: 8_400)
        )
        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        let audit = AppState.makeProductionSingleSessionActivationPreflightAudit(
            decisionRecord: record,
            gateDiagnostics: gate
        )

        XCTAssertEqual(audit.state, .blocked)
        XCTAssertTrue(audit.blockers.contains("operator_approval_expired"))
        XCTAssertTrue(audit.blockers.contains("gate_operator_approval_match_required"))
    }

    func testProductionSingleSessionActivationPreflightAuditScopeMismatchBlocks() {
        let upload = rolloutReadinessDiagnostics()
        let record = approvedDecisionRecord(upload: upload)
        let wrongOrgID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let approval = approvedSingleSessionApproval(upload: upload, orgID: wrongOrgID)
        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        let audit = AppState.makeProductionSingleSessionActivationPreflightAudit(
            decisionRecord: record,
            gateDiagnostics: gate
        )

        XCTAssertEqual(audit.state, .blocked)
        XCTAssertTrue(audit.blockers.contains("decision_record_gate_scope_mismatch"))
        XCTAssertTrue(audit.blockers.contains("gate_exact_scope_match_required"))
    }

    func testProductionSingleSessionActivationPreflightAuditProductionWideEnabledBlocks() {
        let upload = rolloutReadinessDiagnostics(productionWideEnabled: true)
        let record = approvedDecisionRecord(upload: upload)
        let approval = approvedSingleSessionApproval(upload: upload)
        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        let audit = AppState.makeProductionSingleSessionActivationPreflightAudit(
            decisionRecord: record,
            gateDiagnostics: gate
        )

        XCTAssertEqual(audit.state, .blocked)
        XCTAssertFalse(audit.productionWideDisabledConfirmation)
        XCTAssertTrue(audit.blockers.contains("production_wide_canonical_reads_not_disabled"))
        XCTAssertTrue(audit.blockers.contains("gate_production_wide_disabled_not_confirmed"))
    }

    func testProductionSingleSessionActivationPreflightAuditMissingFallbackBlocks() {
        var upload = rolloutReadinessDiagnostics()
        upload.lastCanonicalReadCandidateLocalFallbackAvailable = false
        let record = approvedDecisionRecord(upload: upload)
        let approval = approvedSingleSessionApproval(upload: upload)
        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        let audit = AppState.makeProductionSingleSessionActivationPreflightAudit(
            decisionRecord: record,
            gateDiagnostics: gate
        )

        XCTAssertEqual(audit.state, .blocked)
        XCTAssertFalse(audit.fallbackRetained)
        XCTAssertTrue(audit.blockers.contains("local_fallback_unavailable"))
        XCTAssertTrue(audit.blockers.contains("gate_preflight_not_passed"))
    }

    func testProductionSingleSessionActivationPreflightAuditMissingRollbackBlocks() {
        let upload = rolloutReadinessDiagnostics(rollbackAvailable: false)
        let record = approvedDecisionRecord(upload: upload)
        let approval = approvedSingleSessionApproval(upload: upload)
        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        let audit = AppState.makeProductionSingleSessionActivationPreflightAudit(
            decisionRecord: record,
            gateDiagnostics: gate
        )

        XCTAssertEqual(audit.state, .blocked)
        XCTAssertFalse(audit.rollbackReady)
        XCTAssertTrue(audit.blockers.contains("rollback_not_ready"))
        XCTAssertTrue(audit.blockers.contains("gate_rollback_preflight_not_passed"))
    }

    func testProductionSingleSessionActivationPreflightAuditActivationPerformedBlocks() {
        let upload = rolloutReadinessDiagnostics()
        let record = decisionRecord(from: approvedDecisionRecord(upload: upload), activationPerformed: true)
        let approval = approvedSingleSessionApproval(upload: upload)
        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        let audit = AppState.makeProductionSingleSessionActivationPreflightAudit(
            decisionRecord: record,
            gateDiagnostics: gate
        )

        XCTAssertEqual(audit.state, .blocked)
        XCTAssertTrue(audit.activationPerformed)
        XCTAssertTrue(audit.blockers.contains("activation_performed_must_be_false"))
    }

    func testProductionSingleSessionActivationPreflightAuditReportIncludesNoBehaviorChanges() {
        let upload = rolloutReadinessDiagnostics()
        let record = approvedDecisionRecord(upload: upload)
        let approval = approvedSingleSessionApproval(upload: upload)
        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )
        let audit = AppState.makeProductionSingleSessionActivationPreflightAudit(
            decisionRecord: record,
            gateDiagnostics: gate
        )

        let text = AppState.productionSingleSessionActivationPreflightAuditReportText(audit)

        XCTAssertTrue(text.contains("Production Single-Session Activation Preflight Audit"))
        XCTAssertTrue(text.contains("- preflight_state: ready_for_manual_review_only"))
        XCTAssertTrue(text.contains("- actual_activation_gate_allowed: false"))
        XCTAssertTrue(text.contains("- actual_activation_blockers: production_single_session_canonical_activation_disabled"))
        XCTAssertTrue(text.contains("does not enable production canonical reads"))
        XCTAssertTrue(text.contains("activate candidates"))
        XCTAssertTrue(text.contains("activate overlays"))
        XCTAssertTrue(text.contains("switch reads"))
        XCTAssertTrue(text.contains("hydrate sessions"))
        XCTAssertTrue(text.contains("write local or remote state"))
        XCTAssertTrue(text.contains("remove fallback"))
        XCTAssertTrue(text.contains("change export, seal, sync, media, or iCloud behavior"))
        XCTAssertTrue(text.contains("loosen RLS"))
        XCTAssertTrue(text.contains("change schema"))
        XCTAssertTrue(text.contains("delete data"))
    }

    func testProductionOperatorRolloutRecordPersistencePreflightReadyForReviewOnly() {
        let upload = rolloutReadinessDiagnostics()
        let package = approvedDryRunPackage(upload: upload)
        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)
        let audit = preflightAudit(upload: upload, record: record)

        let preflight = AppState.makeProductionOperatorRolloutRecordPersistencePreflight(
            checkedAt: Date(timeIntervalSinceReferenceDate: 8_900),
            dryRunPackage: package,
            decisionRecord: record,
            activationPreflight: audit
        )

        XCTAssertEqual(preflight.state, .readyForOperatorRecordPersistenceReviewOnly)
        XCTAssertTrue(preflight.blockers.isEmpty)
        XCTAssertEqual(preflight.packageScope, preflight.decisionRecordScope)
        XCTAssertEqual(preflight.packageScope, preflight.preflightRecordScope)
        XCTAssertTrue(preflight.approvalFreshnessRepresented)
        XCTAssertTrue(preflight.approvalFresh)
        XCTAssertTrue(preflight.exactSingleScopeSelected)
        XCTAssertTrue(preflight.decisionRecordReady)
        XCTAssertTrue(preflight.preflightManualReviewOnly)
        XCTAssertTrue(preflight.disabledProductionGateBlockerPresent)
        XCTAssertTrue(preflight.productionWideDisabledConfirmation)
        XCTAssertTrue(preflight.fallbackRetained)
        XCTAssertTrue(preflight.rollbackReady)
        XCTAssertEqual(preflight.activeSource, .local)
        XCTAssertFalse(preflight.activationPerformed)
        XCTAssertFalse(preflight.persistencePerformed)
    }

    func testProductionOperatorRolloutRecordPersistencePreflightMissingApprovalTimestampBlocks() {
        let upload = rolloutReadinessDiagnostics()
        let package = approvedDryRunPackage(
            upload: upload,
            approvalTimestamp: nil,
            expirationTimestamp: Date(timeIntervalSinceReferenceDate: 9_500)
        )
        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)
        let audit = preflightAudit(upload: upload, record: record)

        let preflight = AppState.makeProductionOperatorRolloutRecordPersistencePreflight(
            dryRunPackage: package,
            decisionRecord: record,
            activationPreflight: audit
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertNil(preflight.approvalTimestamp)
        XCTAssertFalse(preflight.approvalFreshnessRepresented)
        XCTAssertTrue(preflight.blockers.contains("operator_approval_timestamp_required"))
        XCTAssertTrue(preflight.blockers.contains("operator_approval_freshness_not_represented"))
    }

    func testProductionOperatorRolloutRecordPersistencePreflightExpiredApprovalBlocks() {
        let upload = rolloutReadinessDiagnostics()
        let package = approvedDryRunPackage(
            upload: upload,
            approvalTimestamp: Date(timeIntervalSinceReferenceDate: 8_200),
            expirationTimestamp: Date(timeIntervalSinceReferenceDate: 8_300),
            checkedAt: Date(timeIntervalSinceReferenceDate: 8_400)
        )
        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)
        let audit = preflightAudit(upload: upload, record: record)

        let preflight = AppState.makeProductionOperatorRolloutRecordPersistencePreflight(
            dryRunPackage: package,
            decisionRecord: record,
            activationPreflight: audit
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertEqual(preflight.approvalState, .expired)
        XCTAssertFalse(preflight.approvalFresh)
        XCTAssertTrue(preflight.blockers.contains("operator_approval_expired_or_stale"))
    }

    func testProductionOperatorRolloutRecordPersistencePreflightScopeMismatchBlocks() {
        let upload = rolloutReadinessDiagnostics()
        let package = approvedDryRunPackage(upload: upload)
        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)
        let wrongSessionID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let wrongRecord = decisionRecord(from: record, sessionID: wrongSessionID)
        let audit = preflightAudit(upload: upload, record: record)

        let preflight = AppState.makeProductionOperatorRolloutRecordPersistencePreflight(
            dryRunPackage: package,
            decisionRecord: wrongRecord,
            activationPreflight: audit
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertNotEqual(preflight.packageScope, preflight.decisionRecordScope)
        XCTAssertTrue(preflight.blockers.contains("operator_rollout_record_scope_mismatch"))
    }

    func testProductionOperatorRolloutRecordPersistencePreflightRequiresManualReviewOnlyAudit() {
        let upload = rolloutReadinessDiagnostics()
        let package = approvedDryRunPackage(upload: upload)
        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)
        let audit = activationPreflight(
            from: preflightAudit(upload: upload, record: record),
            state: .blocked,
            blockers: ["activation_preflight_test_blocker"]
        )

        let preflight = AppState.makeProductionOperatorRolloutRecordPersistencePreflight(
            dryRunPackage: package,
            decisionRecord: record,
            activationPreflight: audit
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.preflightManualReviewOnly)
        XCTAssertTrue(preflight.blockers.contains("activation_preflight_not_manual_review_only"))
    }

    func testProductionOperatorRolloutRecordPersistencePreflightRequiresDisabledProductionGateBlocker() {
        let upload = rolloutReadinessDiagnostics()
        let package = approvedDryRunPackage(upload: upload)
        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)
        let audit = activationPreflight(
            from: preflightAudit(upload: upload, record: record),
            actualActivationBlockers: []
        )

        let preflight = AppState.makeProductionOperatorRolloutRecordPersistencePreflight(
            dryRunPackage: package,
            decisionRecord: record,
            activationPreflight: audit
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.disabledProductionGateBlockerPresent)
        XCTAssertTrue(preflight.blockers.contains("disabled_production_activation_gate_blocker_required"))
    }

    func testProductionOperatorRolloutRecordPersistencePreflightMissingFallbackBlocks() {
        var upload = rolloutReadinessDiagnostics()
        upload.lastCanonicalReadCandidateLocalFallbackAvailable = false
        let package = approvedDryRunPackage(upload: upload)
        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)
        let audit = preflightAudit(upload: upload, record: record)

        let preflight = AppState.makeProductionOperatorRolloutRecordPersistencePreflight(
            dryRunPackage: package,
            decisionRecord: record,
            activationPreflight: audit
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.fallbackRetained)
        XCTAssertTrue(preflight.blockers.contains("local_fallback_unavailable"))
    }

    func testProductionOperatorRolloutRecordPersistencePreflightMissingRollbackBlocks() {
        let upload = rolloutReadinessDiagnostics(rollbackAvailable: false)
        let package = approvedDryRunPackage(upload: upload)
        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)
        let audit = preflightAudit(upload: upload, record: record)

        let preflight = AppState.makeProductionOperatorRolloutRecordPersistencePreflight(
            dryRunPackage: package,
            decisionRecord: record,
            activationPreflight: audit
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.rollbackReady)
        XCTAssertTrue(preflight.blockers.contains("rollback_not_ready"))
    }

    func testProductionOperatorRolloutRecordPersistencePreflightActivationPerformedBlocks() {
        let upload = rolloutReadinessDiagnostics()
        let package = approvedDryRunPackage(upload: upload)
        let record = decisionRecord(
            from: AppState.makeProductionAllowlistDecisionRecord(from: package),
            activationPerformed: true
        )
        let audit = activationPreflight(
            from: preflightAudit(upload: upload, record: record),
            activationPerformed: true
        )

        let preflight = AppState.makeProductionOperatorRolloutRecordPersistencePreflight(
            dryRunPackage: package,
            decisionRecord: record,
            activationPreflight: audit
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertTrue(preflight.activationPerformed)
        XCTAssertTrue(preflight.blockers.contains("activation_performed_must_be_false"))
    }

    func testProductionOperatorRolloutRecordPersistencePreflightReportIncludesNoBehaviorChanges() {
        let upload = rolloutReadinessDiagnostics()
        let package = approvedDryRunPackage(upload: upload)
        let record = AppState.makeProductionAllowlistDecisionRecord(from: package)
        let audit = preflightAudit(upload: upload, record: record)
        let preflight = AppState.makeProductionOperatorRolloutRecordPersistencePreflight(
            dryRunPackage: package,
            decisionRecord: record,
            activationPreflight: audit
        )

        let text = AppState.productionOperatorRolloutRecordPersistencePreflightReportText(preflight)

        XCTAssertTrue(text.contains("Production Operator Rollout Record Persistence Preflight"))
        XCTAssertTrue(text.contains("- persistence_preflight_state: ready_for_operator_record_persistence_review_only"))
        XCTAssertTrue(text.contains("- persistence_performed: false"))
        XCTAssertTrue(text.contains("No operator rollout record was persisted"))
        XCTAssertTrue(text.contains("no activation occurred"))
        XCTAssertTrue(text.contains("no production reads were enabled"))
        XCTAssertTrue(text.contains("no local or remote state was written"))
        XCTAssertTrue(text.contains("no fallback was removed"))
        XCTAssertTrue(text.contains("export, seal, sync, media, iCloud, RLS, schema, and data behavior are unchanged"))
    }

    func testProductionSingleSessionActivationCandidatePackageReadyForManualReviewOnly() {
        let inputs = activationCandidatePackageInputs()

        let candidatePackage = AppState.makeProductionSingleSessionActivationCandidatePackage(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_100),
            dryRunPackage: inputs.package,
            decisionRecord: inputs.record,
            activationPreflight: inputs.audit,
            operatorRecordPersistencePreflight: inputs.persistence,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(candidatePackage.state, .readyForActivationCandidateManualReviewOnly)
        XCTAssertTrue(candidatePackage.blockers.isEmpty)
        XCTAssertEqual(candidatePackage.packageScope, candidatePackage.decisionRecordScope)
        XCTAssertEqual(candidatePackage.packageScope, candidatePackage.activationPreflightScope)
        XCTAssertEqual(candidatePackage.packageScope, candidatePackage.persistencePreflightScope)
        XCTAssertEqual(candidatePackage.packageScope, candidatePackage.gateSelectedScope)
        XCTAssertEqual(candidatePackage.packageScope, candidatePackage.gateApprovedScope)
        XCTAssertEqual(candidatePackage.packageScope, candidatePackage.activationResultScope)
        XCTAssertEqual(candidatePackage.dryRunState, .dryRunReadyForSingleSessionAllowlist)
        XCTAssertTrue(candidatePackage.decisionRecordReady)
        XCTAssertTrue(candidatePackage.activationPreflightManualReviewOnly)
        XCTAssertTrue(candidatePackage.operatorRecordPersistencePreflightReviewOnly)
        XCTAssertTrue(candidatePackage.exactSingleScopeSelected)
        XCTAssertTrue(candidatePackage.productionWideDisabledConfirmation)
        XCTAssertTrue(candidatePackage.productionSingleSessionGateDisabled)
        XCTAssertTrue(candidatePackage.actualActivationRemainsBlocked)
        XCTAssertTrue(candidatePackage.actualActivationBlockers.contains("production_single_session_canonical_activation_disabled"))
        XCTAssertTrue(candidatePackage.actualActivationBlockers.contains("production_canonical_candidate_activation_blocked"))
        XCTAssertTrue(candidatePackage.candidateEvidenceReady)
        XCTAssertTrue(candidatePackage.overlayEvidenceReady)
        XCTAssertTrue(candidatePackage.comparisonEvidenceMatchesLocal)
        XCTAssertTrue(candidatePackage.fallbackRetained)
        XCTAssertTrue(candidatePackage.rollbackReady)
        XCTAssertEqual(candidatePackage.activeSource, .local)
        XCTAssertFalse(candidatePackage.activationPerformed)
        XCTAssertFalse(candidatePackage.persistencePerformed)
    }

    func testProductionSingleSessionActivationCandidatePackageRequires27IPreflightReady() {
        let inputs = activationCandidatePackageInputs()
        let persistence = persistencePreflight(
            from: inputs.persistence,
            state: .blocked,
            blockers: ["persistence_preflight_test_blocker"]
        )

        let candidatePackage = AppState.makeProductionSingleSessionActivationCandidatePackage(
            dryRunPackage: inputs.package,
            decisionRecord: inputs.record,
            activationPreflight: inputs.audit,
            operatorRecordPersistencePreflight: persistence,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(candidatePackage.state, .blocked)
        XCTAssertFalse(candidatePackage.operatorRecordPersistencePreflightReviewOnly)
        XCTAssertTrue(candidatePackage.blockers.contains("operator_record_persistence_preflight_not_ready_for_review"))
    }

    func testProductionSingleSessionActivationCandidatePackageRequires27HPreflightReady() {
        let inputs = activationCandidatePackageInputs()
        let audit = activationPreflight(
            from: inputs.audit,
            state: .blocked,
            blockers: ["activation_preflight_test_blocker"]
        )

        let candidatePackage = AppState.makeProductionSingleSessionActivationCandidatePackage(
            dryRunPackage: inputs.package,
            decisionRecord: inputs.record,
            activationPreflight: audit,
            operatorRecordPersistencePreflight: inputs.persistence,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(candidatePackage.state, .blocked)
        XCTAssertFalse(candidatePackage.activationPreflightManualReviewOnly)
        XCTAssertTrue(candidatePackage.blockers.contains("activation_preflight_not_manual_review_only"))
    }

    func testProductionSingleSessionActivationCandidatePackageGateEnabledOrActivationAllowedBlocks() {
        let inputs = activationCandidatePackageInputs()
        let enabledGate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: true),
            approval: approvedSingleSessionApproval(upload: inputs.upload),
            targetClassification: .approvedProductionValidation,
            diagnostics: inputs.upload
        )
        let activation = AppState.makeCanonicalCandidateActivationResult(
            targetClassification: .approvedProductionValidation,
            diagnostics: inputs.upload,
            productionActivationGate: enabledGate
        )

        let candidatePackage = AppState.makeProductionSingleSessionActivationCandidatePackage(
            dryRunPackage: inputs.package,
            decisionRecord: inputs.record,
            activationPreflight: inputs.audit,
            operatorRecordPersistencePreflight: inputs.persistence,
            gateDiagnostics: enabledGate,
            activationResult: activation
        )

        XCTAssertEqual(candidatePackage.state, .blocked)
        XCTAssertFalse(candidatePackage.productionSingleSessionGateDisabled)
        XCTAssertFalse(candidatePackage.actualActivationRemainsBlocked)
        XCTAssertTrue(candidatePackage.activationPerformed)
        XCTAssertTrue(candidatePackage.blockers.contains("production_single_session_activation_gate_must_remain_disabled"))
        XCTAssertTrue(candidatePackage.blockers.contains("actual_activation_must_remain_blocked"))
        XCTAssertTrue(candidatePackage.blockers.contains("activation_performed_must_be_false"))
    }

    func testProductionSingleSessionActivationCandidatePackageActivationPerformedBlocks() {
        let inputs = activationCandidatePackageInputs()
        let record = decisionRecord(from: inputs.record, activationPerformed: true)
        let audit = activationPreflight(from: inputs.audit, activationPerformed: true)
        let persistence = persistencePreflight(from: inputs.persistence, activationPerformed: true)

        let candidatePackage = AppState.makeProductionSingleSessionActivationCandidatePackage(
            dryRunPackage: inputs.package,
            decisionRecord: record,
            activationPreflight: audit,
            operatorRecordPersistencePreflight: persistence,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(candidatePackage.state, .blocked)
        XCTAssertTrue(candidatePackage.activationPerformed)
        XCTAssertTrue(candidatePackage.blockers.contains("activation_performed_must_be_false"))
    }

    func testProductionSingleSessionActivationCandidatePackagePersistencePerformedBlocks() {
        let inputs = activationCandidatePackageInputs()
        let persistence = persistencePreflight(from: inputs.persistence, persistencePerformed: true)

        let candidatePackage = AppState.makeProductionSingleSessionActivationCandidatePackage(
            dryRunPackage: inputs.package,
            decisionRecord: inputs.record,
            activationPreflight: inputs.audit,
            operatorRecordPersistencePreflight: persistence,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(candidatePackage.state, .blocked)
        XCTAssertTrue(candidatePackage.persistencePerformed)
        XCTAssertTrue(candidatePackage.blockers.contains("persistence_performed_must_be_false"))
    }

    func testProductionSingleSessionActivationCandidatePackageScopeMismatchBlocks() {
        let inputs = activationCandidatePackageInputs()
        let wrongSessionID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let record = decisionRecord(from: inputs.record, sessionID: wrongSessionID)

        let candidatePackage = AppState.makeProductionSingleSessionActivationCandidatePackage(
            dryRunPackage: inputs.package,
            decisionRecord: record,
            activationPreflight: inputs.audit,
            operatorRecordPersistencePreflight: inputs.persistence,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(candidatePackage.state, .blocked)
        XCTAssertNotEqual(candidatePackage.packageScope, candidatePackage.decisionRecordScope)
        XCTAssertTrue(candidatePackage.blockers.contains("activation_candidate_package_scope_mismatch"))
    }

    func testProductionSingleSessionActivationCandidatePackageMissingFallbackBlocks() {
        var upload = rolloutReadinessDiagnostics()
        upload.lastCanonicalReadCandidateLocalFallbackAvailable = false
        let inputs = activationCandidatePackageInputs(upload: upload)

        let candidatePackage = AppState.makeProductionSingleSessionActivationCandidatePackage(
            dryRunPackage: inputs.package,
            decisionRecord: inputs.record,
            activationPreflight: inputs.audit,
            operatorRecordPersistencePreflight: inputs.persistence,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(candidatePackage.state, .blocked)
        XCTAssertFalse(candidatePackage.fallbackRetained)
        XCTAssertTrue(candidatePackage.blockers.contains("local_fallback_unavailable"))
    }

    func testProductionSingleSessionActivationCandidatePackageMissingRollbackBlocks() {
        let upload = rolloutReadinessDiagnostics(rollbackAvailable: false)
        let inputs = activationCandidatePackageInputs(upload: upload)

        let candidatePackage = AppState.makeProductionSingleSessionActivationCandidatePackage(
            dryRunPackage: inputs.package,
            decisionRecord: inputs.record,
            activationPreflight: inputs.audit,
            operatorRecordPersistencePreflight: inputs.persistence,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(candidatePackage.state, .blocked)
        XCTAssertFalse(candidatePackage.rollbackReady)
        XCTAssertTrue(candidatePackage.blockers.contains("rollback_not_ready"))
    }

    func testProductionSingleSessionActivationCandidatePackageProductionWideEnabledBlocks() {
        let upload = rolloutReadinessDiagnostics(productionWideEnabled: true)
        let inputs = activationCandidatePackageInputs(upload: upload)

        let candidatePackage = AppState.makeProductionSingleSessionActivationCandidatePackage(
            dryRunPackage: inputs.package,
            decisionRecord: inputs.record,
            activationPreflight: inputs.audit,
            operatorRecordPersistencePreflight: inputs.persistence,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(candidatePackage.state, .blocked)
        XCTAssertFalse(candidatePackage.productionWideDisabledConfirmation)
        XCTAssertTrue(candidatePackage.blockers.contains("production_wide_canonical_reads_not_disabled"))
    }

    func testProductionSingleSessionActivationCandidatePackageReportIncludesNoBehaviorChanges() {
        let inputs = activationCandidatePackageInputs()
        let candidatePackage = AppState.makeProductionSingleSessionActivationCandidatePackage(
            dryRunPackage: inputs.package,
            decisionRecord: inputs.record,
            activationPreflight: inputs.audit,
            operatorRecordPersistencePreflight: inputs.persistence,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        let text = AppState.productionSingleSessionActivationCandidatePackageReportText(candidatePackage)

        XCTAssertTrue(text.contains("Production Single-Session Activation Candidate Package"))
        XCTAssertTrue(text.contains("- candidate_package_state: ready_for_activation_candidate_manual_review_only"))
        XCTAssertTrue(text.contains("- production_single_session_gate_disabled: true"))
        XCTAssertTrue(text.contains("- actual_activation_remains_blocked: true"))
        XCTAssertTrue(text.contains("- activation_performed: false"))
        XCTAssertTrue(text.contains("- persistence_performed: false"))
        XCTAssertTrue(text.contains("No production reads were enabled"))
        XCTAssertTrue(text.contains("no activation occurred"))
        XCTAssertTrue(text.contains("no overlay was activated"))
        XCTAssertTrue(text.contains("no hydration occurred"))
        XCTAssertTrue(text.contains("no reads were switched"))
        XCTAssertTrue(text.contains("no local or remote state was written"))
        XCTAssertTrue(text.contains("no fallback was removed"))
        XCTAssertTrue(text.contains("export, seal, sync, media, iCloud, RLS, schema, and data behavior is unchanged"))
    }

    func testProductionSingleSessionActivationReadinessValidationReadyForReviewOnly() {
        let inputs = activationReadinessValidationInputs()

        let validation = AppState.makeProductionSingleSessionActivationReadinessValidation(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_300),
            candidatePackage: inputs.candidatePackage,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(validation.state, .readyForActivationReadinessReviewOnly)
        XCTAssertTrue(validation.blockers.isEmpty)
        XCTAssertTrue(validation.candidatePackageReadyForManualReviewOnly)
        XCTAssertTrue(validation.exactSingleScopeSelected)
        XCTAssertEqual(validation.candidatePackageScope, validation.gateSelectedScope)
        XCTAssertEqual(validation.candidatePackageScope, validation.gateApprovedScope)
        XCTAssertEqual(validation.candidatePackageScope, validation.activationResultScope)
        XCTAssertTrue(validation.productionWideDisabledConfirmation)
        XCTAssertTrue(validation.productionSingleSessionGateDisabled)
        XCTAssertTrue(validation.actualActivationRemainsBlocked)
        XCTAssertTrue(validation.actualActivationBlockers.contains("production_single_session_canonical_activation_disabled"))
        XCTAssertTrue(validation.actualActivationBlockers.contains("production_canonical_candidate_activation_blocked"))
        XCTAssertEqual(validation.activeSource, .local)
        XCTAssertFalse(validation.activationPerformed)
        XCTAssertFalse(validation.persistencePerformed)
        XCTAssertFalse(validation.hydrationPerformed)
        XCTAssertTrue(validation.productionHydrationDisabledConfirmation)
        XCTAssertTrue(validation.fallbackRetained)
        XCTAssertTrue(validation.rollbackReady)
        XCTAssertTrue(validation.candidateEvidenceReady)
        XCTAssertTrue(validation.overlayEvidenceReady)
        XCTAssertTrue(validation.comparisonEvidenceMatchesLocal)
    }

    func testProductionSingleSessionActivationReadinessValidationRequires27JReady() {
        let inputs = activationReadinessValidationInputs()
        let candidatePackage = activationCandidatePackage(
            from: inputs.candidatePackage,
            state: .blocked,
            blockers: ["candidate_package_test_blocker"]
        )

        let validation = AppState.makeProductionSingleSessionActivationReadinessValidation(
            candidatePackage: candidatePackage,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertFalse(validation.candidatePackageReadyForManualReviewOnly)
        XCTAssertTrue(validation.blockers.contains("activation_candidate_package_not_manual_review_only"))
    }

    func testProductionSingleSessionActivationReadinessValidationGateEnabledBlocks() {
        let inputs = activationReadinessValidationInputs()
        let enabledGate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: true),
            approval: approvedSingleSessionApproval(upload: inputs.upload),
            targetClassification: .approvedProductionValidation,
            diagnostics: inputs.upload
        )

        let validation = AppState.makeProductionSingleSessionActivationReadinessValidation(
            candidatePackage: inputs.candidatePackage,
            gateDiagnostics: enabledGate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertFalse(validation.productionSingleSessionGateDisabled)
        XCTAssertFalse(validation.actualActivationRemainsBlocked)
        XCTAssertTrue(validation.blockers.contains("production_single_session_activation_gate_must_remain_disabled"))
        XCTAssertTrue(validation.blockers.contains("actual_activation_must_remain_blocked"))
    }

    func testProductionSingleSessionActivationReadinessValidationActualActivationAllowedBlocks() {
        let inputs = activationReadinessValidationInputs()
        let activation = activationResult(
            from: inputs.activation,
            allowed: true,
            activeSource: .local
        )

        let validation = AppState.makeProductionSingleSessionActivationReadinessValidation(
            candidatePackage: inputs.candidatePackage,
            gateDiagnostics: inputs.gate,
            activationResult: activation
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertFalse(validation.actualActivationRemainsBlocked)
        XCTAssertTrue(validation.activationPerformed)
        XCTAssertTrue(validation.blockers.contains("actual_activation_must_remain_blocked"))
        XCTAssertTrue(validation.blockers.contains("activation_performed_must_be_false"))
    }

    func testProductionSingleSessionActivationReadinessValidationActiveSourceNotLocalBlocks() {
        let inputs = activationReadinessValidationInputs()
        let activation = activationResult(
            from: inputs.activation,
            allowed: false,
            activeSource: .canonicalCandidate
        )

        let validation = AppState.makeProductionSingleSessionActivationReadinessValidation(
            candidatePackage: inputs.candidatePackage,
            gateDiagnostics: inputs.gate,
            activationResult: activation
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertEqual(validation.activeSource, .canonicalCandidate)
        XCTAssertTrue(validation.activationPerformed)
        XCTAssertTrue(validation.blockers.contains("active_source_must_remain_local"))
        XCTAssertTrue(validation.blockers.contains("activation_performed_must_be_false"))
    }

    func testProductionSingleSessionActivationReadinessValidationActivationPerformedBlocks() {
        let inputs = activationReadinessValidationInputs()
        let candidatePackage = activationCandidatePackage(
            from: inputs.candidatePackage,
            activationPerformed: true
        )

        let validation = AppState.makeProductionSingleSessionActivationReadinessValidation(
            candidatePackage: candidatePackage,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.activationPerformed)
        XCTAssertTrue(validation.blockers.contains("activation_performed_must_be_false"))
    }

    func testProductionSingleSessionActivationReadinessValidationPersistencePerformedBlocks() {
        let inputs = activationReadinessValidationInputs()
        let candidatePackage = activationCandidatePackage(
            from: inputs.candidatePackage,
            persistencePerformed: true
        )

        let validation = AppState.makeProductionSingleSessionActivationReadinessValidation(
            candidatePackage: candidatePackage,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.persistencePerformed)
        XCTAssertTrue(validation.blockers.contains("persistence_performed_must_be_false"))
    }

    func testProductionSingleSessionActivationReadinessValidationMissingFallbackBlocks() {
        let inputs = activationReadinessValidationInputs()
        let candidatePackage = activationCandidatePackage(
            from: inputs.candidatePackage,
            fallbackRetained: false
        )

        let validation = AppState.makeProductionSingleSessionActivationReadinessValidation(
            candidatePackage: candidatePackage,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertFalse(validation.fallbackRetained)
        XCTAssertTrue(validation.blockers.contains("local_fallback_unavailable"))
    }

    func testProductionSingleSessionActivationReadinessValidationMissingRollbackBlocks() {
        let inputs = activationReadinessValidationInputs()
        let candidatePackage = activationCandidatePackage(
            from: inputs.candidatePackage,
            rollbackReady: false
        )

        let validation = AppState.makeProductionSingleSessionActivationReadinessValidation(
            candidatePackage: candidatePackage,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertFalse(validation.rollbackReady)
        XCTAssertTrue(validation.blockers.contains("rollback_not_ready"))
    }

    func testProductionSingleSessionActivationReadinessValidationProductionWideEnabledBlocks() {
        let inputs = activationReadinessValidationInputs()
        let candidatePackage = activationCandidatePackage(
            from: inputs.candidatePackage,
            productionWideDisabledConfirmation: false
        )

        let validation = AppState.makeProductionSingleSessionActivationReadinessValidation(
            candidatePackage: candidatePackage,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertFalse(validation.productionWideDisabledConfirmation)
        XCTAssertTrue(validation.blockers.contains("production_wide_canonical_reads_not_disabled"))
    }

    func testProductionSingleSessionActivationReadinessValidationReportIncludesNoBehaviorChanges() {
        let inputs = activationReadinessValidationInputs()
        let validation = AppState.makeProductionSingleSessionActivationReadinessValidation(
            candidatePackage: inputs.candidatePackage,
            gateDiagnostics: inputs.gate,
            activationResult: inputs.activation
        )

        let text = AppState.productionSingleSessionActivationReadinessValidationReportText(validation)

        XCTAssertTrue(text.contains("Production Single-Session Activation Readiness Validation"))
        XCTAssertTrue(text.contains("- activation_readiness_validation_state: ready_for_activation_readiness_review_only"))
        XCTAssertTrue(text.contains("- production_single_session_gate_disabled: true"))
        XCTAssertTrue(text.contains("- actual_activation_remains_blocked: true"))
        XCTAssertTrue(text.contains("- activation_performed: false"))
        XCTAssertTrue(text.contains("- persistence_performed: false"))
        XCTAssertTrue(text.contains("- hydration_performed: false"))
        XCTAssertTrue(text.contains("No production reads were enabled"))
        XCTAssertTrue(text.contains("no activation occurred"))
        XCTAssertTrue(text.contains("no overlay was activated"))
        XCTAssertTrue(text.contains("no hydration occurred"))
        XCTAssertTrue(text.contains("no reads were switched"))
        XCTAssertTrue(text.contains("no local or remote state was written"))
        XCTAssertTrue(text.contains("no fallback was removed"))
        XCTAssertTrue(text.contains("export, seal, sync, media, iCloud, RLS, schema, and data behavior is unchanged"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightReadyForReviewOnly() {
        let inputs = hydrationReadinessPreflightInputs()

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_500),
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: inputs.confirmation
        )

        XCTAssertEqual(preflight.state, .readyForHydrationReadinessReviewOnly)
        XCTAssertTrue(preflight.blockers.isEmpty)
        XCTAssertTrue(preflight.activationReadinessReviewOnly)
        XCTAssertTrue(preflight.exactSingleScopeSelected)
        XCTAssertEqual(preflight.activationReadinessScope, preflight.candidatePackageScope)
        XCTAssertEqual(preflight.candidatePackageScope, preflight.restoreDiagnosticsScope)
        XCTAssertTrue(preflight.restoreDiagnosticsScopeMatchesPackage)
        XCTAssertTrue(preflight.hydrationConfirmationMatchesScope)
        XCTAssertEqual(preflight.restoreResult, .restorableMetadataCandidate)
        XCTAssertTrue(preflight.snapshotIDPresent)
        XCTAssertTrue(preflight.checksumVerified)
        XCTAssertTrue(preflight.rowObjectVerified)
        XCTAssertTrue(preflight.parentRemoteVerified)
        XCTAssertTrue(preflight.snapshotSchemaSupported)
        XCTAssertTrue(preflight.freshnessNotLocalNewer)
        XCTAssertTrue(preflight.productionHydrationDisabledNonWriting)
        XCTAssertEqual(preflight.productionHydrationBlockedReason, "production_hydration_gate_disabled")
        XCTAssertTrue(preflight.hydrationExecutionBlocked)
        XCTAssertFalse(preflight.hydrationPerformed)
        XCTAssertEqual(preflight.activeSource, .local)
        XCTAssertFalse(preflight.activationPerformed)
        XCTAssertFalse(preflight.persistencePerformed)
        XCTAssertTrue(preflight.fallbackRetained)
        XCTAssertTrue(preflight.rollbackReady)
    }

    func testProductionSingleSessionHydrationReadinessPreflightReportsExplicitBlockedConditions() {
        let inputs = hydrationReadinessPreflightInputs()

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: inputs.confirmation
        )
        let text = AppState.productionSingleSessionHydrationReadinessPreflightReportText(preflight)

        XCTAssertTrue(preflight.blockedConditions.contains("production_hydration_disabled_non_writing"))
        XCTAssertTrue(preflight.blockedConditions.contains("hydration_execution_blocked"))
        XCTAssertTrue(preflight.blockedConditions.contains("actual_activation_blocked"))
        XCTAssertTrue(preflight.blockedConditions.contains("production_canonical_reads_disabled"))
        XCTAssertTrue(preflight.blockedConditions.contains("local_remote_state_writes_blocked"))
        XCTAssertTrue(text.contains("- blocked_conditions:"))
        XCTAssertTrue(text.contains("production_hydration_disabled_non_writing"))
        XCTAssertTrue(text.contains("local_remote_state_writes_blocked"))
        XCTAssertTrue(text.contains("- production_hydration_disabled_non_writing: true"))
        XCTAssertTrue(text.contains("- hydration_execution_blocked: true"))
        XCTAssertTrue(text.contains("production hydration remains disabled and non-writing"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightRequires27KReady() {
        let inputs = hydrationReadinessPreflightInputs()
        let validation = activationReadinessValidation(
            from: inputs.validation,
            state: .blocked,
            blockers: ["activation_readiness_test_blocker"]
        )

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: inputs.confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.activationReadinessReviewOnly)
        XCTAssertTrue(preflight.blockers.contains("activation_readiness_validation_not_review_only"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightScopeMismatchBlocks() {
        let inputs = hydrationReadinessPreflightInputs()
        let restore = restoreDiagnostics(propertyID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!)
        let confirmation = hydrationConfirmation(restore: restore, policy: inputs.policy)

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.restoreDiagnosticsScopeMatchesPackage)
        XCTAssertTrue(preflight.blockers.contains("hydration_readiness_scope_mismatch"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightRestoreNotRestorableBlocks() {
        let inputs = hydrationReadinessPreflightInputs()
        let restore = restoreDiagnostics(result: .objectMissing)
        let confirmation = hydrationConfirmation(restore: restore, policy: inputs.policy)

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertEqual(preflight.restoreResult, .objectMissing)
        XCTAssertTrue(preflight.blockers.contains("restore_diagnostics_not_restorable"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightMissingSnapshotIDBlocks() {
        let inputs = hydrationReadinessPreflightInputs()
        let restore = restoreDiagnostics(includeSnapshotID: false)
        let confirmation = hydrationConfirmation(restore: restore, policy: inputs.policy)

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.snapshotIDPresent)
        XCTAssertTrue(preflight.blockers.contains("snapshot_id_required"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightChecksumFailureBlocks() {
        let inputs = hydrationReadinessPreflightInputs()
        let restore = restoreDiagnostics(checksumVerified: false)
        let confirmation = hydrationConfirmation(restore: restore, policy: inputs.policy)

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.checksumVerified)
        XCTAssertTrue(preflight.blockers.contains("restore_checksum_not_verified"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightParentAndRowVerificationFailureBlocks() {
        let inputs = hydrationReadinessPreflightInputs()
        let restore = restoreDiagnostics(rowObjectVerified: false, parentRemoteVerified: false)
        let confirmation = hydrationConfirmation(restore: restore, policy: inputs.policy)

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.rowObjectVerified)
        XCTAssertFalse(preflight.parentRemoteVerified)
        XCTAssertTrue(preflight.blockers.contains("restore_row_object_not_verified"))
        XCTAssertTrue(preflight.blockers.contains("restore_parent_remote_not_verified"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightUnsupportedSchemaBlocks() {
        let inputs = hydrationReadinessPreflightInputs()
        let restore = restoreDiagnostics(snapshotSchemaVersion: 2)
        let confirmation = hydrationConfirmation(restore: restore, policy: inputs.policy)

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.snapshotSchemaSupported)
        XCTAssertTrue(preflight.blockers.contains("restore_snapshot_schema_not_supported"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightLocalNewerFreshnessBlocks() {
        let inputs = hydrationReadinessPreflightInputs()
        let restore = restoreDiagnostics(freshness: "local_newer")
        let confirmation = hydrationConfirmation(restore: restore, policy: inputs.policy)

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.freshnessNotLocalNewer)
        XCTAssertTrue(preflight.blockers.contains("restore_freshness_local_newer"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightProductionHydrationEnabledBlocks() {
        let inputs = hydrationReadinessPreflightInputs()
        let policy = hydrationPolicy(productionHydrationAllowed: true, hydrationAvailable: true)
        let confirmation = hydrationConfirmation(restore: inputs.restore, policy: policy)

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: policy,
            hydrationConfirmation: confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.productionHydrationDisabledNonWriting)
        XCTAssertFalse(preflight.hydrationExecutionBlocked)
        XCTAssertTrue(preflight.blockers.contains("production_hydration_must_remain_disabled"))
        XCTAssertTrue(preflight.blockers.contains("hydration_execution_must_remain_blocked"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightActivationPerformedBlocks() {
        let inputs = hydrationReadinessPreflightInputs()
        let validation = activationReadinessValidation(
            from: inputs.validation,
            activationPerformed: true
        )

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: inputs.confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertTrue(preflight.activationPerformed)
        XCTAssertTrue(preflight.blockers.contains("activation_performed_must_be_false"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightPersistencePerformedBlocks() {
        let inputs = hydrationReadinessPreflightInputs()
        let validation = activationReadinessValidation(
            from: inputs.validation,
            persistencePerformed: true
        )

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: inputs.confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertTrue(preflight.persistencePerformed)
        XCTAssertTrue(preflight.blockers.contains("persistence_performed_must_be_false"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightMissingFallbackBlocks() {
        let inputs = hydrationReadinessPreflightInputs()
        let validation = activationReadinessValidation(
            from: inputs.validation,
            fallbackRetained: false
        )

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: inputs.confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.fallbackRetained)
        XCTAssertTrue(preflight.blockers.contains("local_fallback_unavailable"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightMissingRollbackBlocks() {
        let inputs = hydrationReadinessPreflightInputs()
        let validation = activationReadinessValidation(
            from: inputs.validation,
            rollbackReady: false
        )

        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: inputs.confirmation
        )

        XCTAssertEqual(preflight.state, .blocked)
        XCTAssertFalse(preflight.rollbackReady)
        XCTAssertTrue(preflight.blockers.contains("rollback_not_ready"))
    }

    func testProductionSingleSessionHydrationReadinessPreflightReportIncludesNoBehaviorChanges() {
        let inputs = hydrationReadinessPreflightInputs()
        let preflight = AppState.makeProductionSingleSessionHydrationReadinessPreflight(
            activationReadiness: inputs.validation,
            candidatePackage: inputs.candidatePackage,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            hydrationConfirmation: inputs.confirmation
        )

        let text = AppState.productionSingleSessionHydrationReadinessPreflightReportText(preflight)

        XCTAssertTrue(text.contains("Production Single-Session Hydration Readiness Preflight"))
        XCTAssertTrue(text.contains("- hydration_readiness_preflight_state: ready_for_hydration_readiness_review_only"))
        XCTAssertTrue(text.contains("- hydration_performed: false"))
        XCTAssertTrue(text.contains("No hydration occurred"))
        XCTAssertTrue(text.contains("production hydration remains disabled and non-writing"))
        XCTAssertTrue(text.contains("no production reads were enabled"))
        XCTAssertTrue(text.contains("no activation occurred"))
        XCTAssertTrue(text.contains("no overlay was activated"))
        XCTAssertTrue(text.contains("no reads were switched"))
        XCTAssertTrue(text.contains("no local or remote state was written"))
        XCTAssertTrue(text.contains("no fallback was removed"))
        XCTAssertTrue(text.contains("export, seal, sync, media, iCloud, RLS, schema, and data behavior is unchanged"))
    }

    func testProductionSingleSessionHydrationExecutionRehearsalPassesForTestOnlyFixture() {
        let inputs = hydrationExecutionRehearsalInputs()

        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_600),
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        XCTAssertEqual(rehearsal.state, .testOnlyHydrationRehearsalPassed)
        XCTAssertTrue(rehearsal.blockers.isEmpty)
        XCTAssertTrue(rehearsal.blockedConditions.contains("test_only_fixture_hydration_only"))
        XCTAssertTrue(rehearsal.blockedConditions.contains("production_hydration_blocked"))
        XCTAssertTrue(rehearsal.blockedConditions.contains("production_reads_blocked"))
        XCTAssertTrue(rehearsal.blockedConditions.contains("remote_state_writes_blocked"))
        XCTAssertTrue(rehearsal.blockedConditions.contains("real_local_user_state_writes_blocked"))
        XCTAssertTrue(rehearsal.blockedConditions.contains("rollback_restored_pre_hydration_fixture_state"))
        XCTAssertTrue(rehearsal.hydrationReadinessReviewOnly)
        XCTAssertTrue(rehearsal.exactSingleScopeSelected)
        XCTAssertTrue(rehearsal.scopesMatch)
        XCTAssertTrue(rehearsal.productionHydrationDisabled)
        XCTAssertTrue(rehearsal.executionTargetIsLocalTestFixture)
        XCTAssertTrue(rehearsal.productionTargetBlocked)
        XCTAssertTrue(rehearsal.productionReadsBlocked)
        XCTAssertTrue(rehearsal.remoteStateWritesBlocked)
        XCTAssertTrue(rehearsal.realLocalUserStateWritesBlocked)
        XCTAssertTrue(rehearsal.hydrationOperationSucceeded)
        XCTAssertTrue(rehearsal.postHydrationMatchesSnapshotEvidence)
        XCTAssertTrue(rehearsal.rollbackOperationSucceeded)
        XCTAssertTrue(rehearsal.rollbackRestoredPreHydrationFixture)
        XCTAssertTrue(rehearsal.fallbackRetained)
    }

    func testProductionSingleSessionHydrationExecutionRehearsalRequires27LReady() {
        var inputs = hydrationExecutionRehearsalInputs()
        inputs.preflight = hydrationReadinessPreflight(
            state: .blocked,
            blockers: ["hydration_readiness_test_blocker"]
        )

        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        XCTAssertEqual(rehearsal.state, .blocked)
        XCTAssertFalse(rehearsal.hydrationReadinessReviewOnly)
        XCTAssertTrue(rehearsal.blockers.contains("hydration_readiness_preflight_not_review_only"))
    }

    func testProductionSingleSessionHydrationExecutionRehearsalProductionTargetBlocks() {
        var inputs = hydrationExecutionRehearsalInputs()
        inputs.hydrationOperation = rehearsalOperationEvidence(
            operationName: "fixture_hydration",
            productionTarget: true
        )

        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        XCTAssertEqual(rehearsal.state, .blocked)
        XCTAssertFalse(rehearsal.productionTargetBlocked)
        XCTAssertTrue(rehearsal.blockers.contains("production_target_not_allowed_for_hydration_rehearsal"))
    }

    func testProductionSingleSessionHydrationExecutionRehearsalScopeMismatchBlocks() {
        var inputs = hydrationExecutionRehearsalInputs()
        let mismatchedScope = AppState.ProductionCohortApprovalScope(
            orgID: orgID,
            propertyID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            sessionID: sessionID
        )
        inputs.postFixture = fixtureMetadataEvidence(fingerprint: "post-fixture", scope: mismatchedScope)

        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        XCTAssertEqual(rehearsal.state, .blocked)
        XCTAssertFalse(rehearsal.scopesMatch)
        XCTAssertTrue(rehearsal.blockers.contains("hydration_rehearsal_scope_mismatch"))
    }

    func testProductionSingleSessionHydrationExecutionRehearsalHydrationOperationFailureBlocks() {
        var inputs = hydrationExecutionRehearsalInputs()
        inputs.hydrationOperation = rehearsalOperationEvidence(
            operationName: "fixture_hydration",
            succeeded: false,
            failureReason: "fixture_hydration_failed"
        )

        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        XCTAssertEqual(rehearsal.state, .blocked)
        XCTAssertFalse(rehearsal.hydrationOperationSucceeded)
        XCTAssertTrue(rehearsal.blockers.contains("fixture_hydration_operation_failed"))
    }

    func testProductionSingleSessionHydrationExecutionRehearsalPostHydrationMismatchBlocks() {
        var inputs = hydrationExecutionRehearsalInputs()
        inputs.postFixture = fixtureMetadataEvidence(fingerprint: "post-fixture", shotCount: 4)

        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        XCTAssertEqual(rehearsal.state, .blocked)
        XCTAssertFalse(rehearsal.postHydrationMatchesSnapshotEvidence)
        XCTAssertTrue(rehearsal.blockers.contains("post_hydration_fixture_mismatch"))
    }

    func testProductionSingleSessionHydrationExecutionRehearsalRollbackFailureBlocks() {
        var inputs = hydrationExecutionRehearsalInputs()
        inputs.rollbackOperation = rehearsalOperationEvidence(
            operationName: "fixture_rollback",
            succeeded: false,
            fingerprint: "pre-fixture",
            shotCount: 1,
            issueCount: 0,
            guidedCount: 0,
            failureReason: "fixture_rollback_failed"
        )

        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        XCTAssertEqual(rehearsal.state, .blocked)
        XCTAssertFalse(rehearsal.rollbackOperationSucceeded)
        XCTAssertTrue(rehearsal.blockers.contains("fixture_rollback_operation_failed"))
    }

    func testProductionSingleSessionHydrationExecutionRehearsalRollbackRestoredMismatchBlocks() {
        var inputs = hydrationExecutionRehearsalInputs()
        inputs.restoredFixture = fixtureMetadataEvidence(
            fingerprint: "wrong-restored-fixture",
            shotCount: 1,
            issueCount: 0,
            guidedCount: 0
        )

        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        XCTAssertEqual(rehearsal.state, .blocked)
        XCTAssertFalse(rehearsal.rollbackRestoredPreHydrationFixture)
        XCTAssertTrue(rehearsal.blockers.contains("rollback_restored_fixture_mismatch"))
    }

    func testProductionSingleSessionHydrationExecutionRehearsalRemoteWriteAttemptBlocks() {
        var inputs = hydrationExecutionRehearsalInputs()
        inputs.hydrationOperation = rehearsalOperationEvidence(
            operationName: "fixture_hydration",
            remoteStateWriteAttempted: true
        )

        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        XCTAssertEqual(rehearsal.state, .blocked)
        XCTAssertFalse(rehearsal.remoteStateWritesBlocked)
        XCTAssertTrue(rehearsal.blockers.contains("remote_state_write_attempted"))
    }

    func testProductionSingleSessionHydrationExecutionRehearsalProductionReadAttemptBlocks() {
        var inputs = hydrationExecutionRehearsalInputs()
        inputs.hydrationOperation = rehearsalOperationEvidence(
            operationName: "fixture_hydration",
            productionReadsEnabled: true
        )

        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        XCTAssertEqual(rehearsal.state, .blocked)
        XCTAssertFalse(rehearsal.productionReadsBlocked)
        XCTAssertTrue(rehearsal.blockers.contains("production_reads_must_remain_disabled"))
    }

    func testProductionSingleSessionHydrationExecutionRehearsalRealLocalUserStateWriteAttemptBlocks() {
        var inputs = hydrationExecutionRehearsalInputs()
        inputs.hydrationOperation = rehearsalOperationEvidence(
            operationName: "fixture_hydration",
            realLocalUserStateWriteAttempted: true
        )

        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        XCTAssertEqual(rehearsal.state, .blocked)
        XCTAssertFalse(rehearsal.realLocalUserStateWritesBlocked)
        XCTAssertTrue(rehearsal.blockers.contains("real_local_user_state_write_attempted"))
    }

    func testProductionSingleSessionHydrationExecutionRehearsalMissingFallbackBlocks() {
        var inputs = hydrationExecutionRehearsalInputs()
        inputs.preflight = hydrationReadinessPreflight(fallbackRetained: false)

        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        XCTAssertEqual(rehearsal.state, .blocked)
        XCTAssertFalse(rehearsal.fallbackRetained)
        XCTAssertTrue(rehearsal.blockers.contains("local_fallback_unavailable"))
    }

    func testProductionSingleSessionHydrationExecutionRehearsalReportIncludesNoProductionBehaviorChanges() {
        let inputs = hydrationExecutionRehearsalInputs()
        let rehearsal = AppState.makeProductionSingleSessionHydrationExecutionRehearsal(
            hydrationReadiness: inputs.preflight,
            restoreDiagnostics: inputs.restore,
            hydrationPolicy: inputs.policy,
            preHydrationFixture: inputs.preFixture,
            hydrationOperation: inputs.hydrationOperation,
            postHydrationFixture: inputs.postFixture,
            rollbackOperation: inputs.rollbackOperation,
            restoredFixture: inputs.restoredFixture
        )

        let text = AppState.productionSingleSessionHydrationExecutionRehearsalReportText(rehearsal)

        XCTAssertTrue(text.contains("Production Single-Session Hydration Execution Rehearsal"))
        XCTAssertTrue(text.contains("- hydration_execution_rehearsal_state: test_only_hydration_rehearsal_passed"))
        XCTAssertTrue(text.contains("- blocked_conditions:"))
        XCTAssertTrue(text.contains("test_only_fixture_hydration_only"))
        XCTAssertTrue(text.contains("- remote_state_writes_blocked: true"))
        XCTAssertTrue(text.contains("- real_local_user_state_writes_blocked: true"))
        XCTAssertTrue(text.contains("test-only fixture hydration only"))
        XCTAssertTrue(text.contains("No production hydration occurred"))
        XCTAssertTrue(text.contains("no production reads were enabled"))
        XCTAssertTrue(text.contains("no activation occurred"))
        XCTAssertTrue(text.contains("no overlay was activated"))
        XCTAssertTrue(text.contains("no reads were switched"))
        XCTAssertTrue(text.contains("no remote state was written"))
        XCTAssertTrue(text.contains("no real local user state was written"))
        XCTAssertTrue(text.contains("no fallback was removed"))
        XCTAssertTrue(text.contains("rollback restored pre-hydration fixture state or fallback remained retained"))
        XCTAssertTrue(text.contains("export, seal, sync, media, iCloud, RLS, schema, and data behavior is unchanged"))
    }

    @MainActor
    func testProductionSingleSessionMediaRestorationRehearsalRestoresChecksumVerifiedMediaIntoPackageCandidate() throws {
        let fixture = try makeActivationExecutionFixture()
        defer { tearDownActivationExecutionFixture(fixture) }
        let candidateID = UUID()
        let bytes = Data("phase-2c-27o-media".utf8)

        let rehearsal = fixture.appState.rehearseProductionSingleSessionMediaRestorationForTests(
            hydrationRehearsal: hydrationExecutionRehearsal(),
            candidateID: candidateID,
            mediaItems: [
                mediaRestorationItem(filename: "verified.jpg", data: bytes)
            ],
            targetClassification: .localDev
        )

        let candidateURL = fixture.appState.productionSingleSessionMediaRestorationCandidateDirectoryURLForTests(
            propertyID: propertyID,
            sessionID: sessionID,
            candidateID: candidateID
        )
        let restoredURL = candidateURL.appendingPathComponent("verified.jpg", isDirectory: false)
        let originalURL = fixture.store
            .originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent("verified.jpg", isDirectory: false)

        XCTAssertEqual(rehearsal.state, .testOnlyMediaRestorationRehearsalPassed)
        XCTAssertTrue(rehearsal.blockers.isEmpty)
        XCTAssertTrue(rehearsal.hydrationExecutionRehearsalPassed)
        XCTAssertTrue(rehearsal.executionTargetIsLocalTestFixture)
        XCTAssertTrue(rehearsal.productionReadsBlocked)
        XCTAssertTrue(rehearsal.broadCanonicalReadBlocked)
        XCTAssertTrue(rehearsal.remoteStateWritesBlocked)
        XCTAssertTrue(rehearsal.realLocalUserStateWritesBlocked)
        XCTAssertTrue(rehearsal.checksumVerificationRequired)
        XCTAssertTrue(rehearsal.restoredMediaLandedInPackageCandidate)
        XCTAssertTrue(rehearsal.originalsOverwriteBlocked)
        XCTAssertTrue(rehearsal.existingOriginalsPreserved)
        XCTAssertTrue(rehearsal.fallbackRetained)
        XCTAssertTrue(rehearsal.exportSealSyncMediaICloudUnchanged)
        XCTAssertEqual(rehearsal.restoredCount, 1)
        XCTAssertEqual(rehearsal.acceptedCandidateMediaCount, 1)
        XCTAssertEqual(rehearsal.itemEvidence.first?.status, .restored)
        XCTAssertEqual(rehearsal.itemEvidence.first?.checksumVerifiedBeforeAcceptance, true)
        XCTAssertEqual(try Data(contentsOf: restoredURL), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))

        let text = AppState.productionSingleSessionMediaRestorationRehearsalReportText(rehearsal)
        XCTAssertTrue(text.contains("Production Single-Session Media Restoration Rehearsal"))
        XCTAssertTrue(text.contains("- media_restoration_rehearsal_state: test_only_media_restoration_rehearsal_passed"))
        XCTAssertTrue(text.contains("No production reads were enabled"))
        XCTAssertTrue(text.contains("no remote state was written"))
        XCTAssertTrue(text.contains("no originals were overwritten"))
    }

    @MainActor
    func testProductionSingleSessionMediaRestorationRehearsalSkipsChecksumVerifiedDuplicateAndRollbackPreservesIt() throws {
        let fixture = try makeActivationExecutionFixture()
        defer { tearDownActivationExecutionFixture(fixture) }
        let candidateID = UUID()
        let existingBytes = Data("existing-candidate".utf8)
        let candidateURL = fixture.appState.productionSingleSessionMediaRestorationCandidateDirectoryURLForTests(
            propertyID: propertyID,
            sessionID: sessionID,
            candidateID: candidateID
        )
        try FileManager.default.createDirectory(at: candidateURL, withIntermediateDirectories: true)
        let existingURL = candidateURL.appendingPathComponent("duplicate.jpg", isDirectory: false)
        try existingBytes.write(to: existingURL, options: .atomic)

        let rehearsal = fixture.appState.rehearseProductionSingleSessionMediaRestorationForTests(
            hydrationRehearsal: hydrationExecutionRehearsal(),
            candidateID: candidateID,
            mediaItems: [
                mediaRestorationItem(filename: "duplicate.jpg", data: existingBytes)
            ],
            targetClassification: .localDev
        )

        XCTAssertEqual(rehearsal.state, .testOnlyMediaRestorationRehearsalPassed)
        XCTAssertEqual(rehearsal.restoredCount, 0)
        XCTAssertEqual(rehearsal.skippedExistingCount, 1)
        XCTAssertEqual(rehearsal.acceptedCandidateMediaCount, 1)
        XCTAssertTrue(rehearsal.duplicateRestorationIdempotent)
        XCTAssertEqual(rehearsal.itemEvidence.first?.status, .skippedExisting)
        XCTAssertEqual(rehearsal.itemEvidence.first?.checksumVerifiedBeforeAcceptance, true)
        XCTAssertTrue(rehearsal.createdCandidateFilePaths.isEmpty)
        XCTAssertTrue(rehearsal.createdCandidateDirectoryPaths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: existingURL), existingBytes)

        let rollback = fixture.appState.rollbackProductionSingleSessionMediaRestorationRehearsalForTests(
            rehearsal: rehearsal
        )

        XCTAssertEqual(rollback.state, .restoredPreRestorationFixture)
        XCTAssertFalse(rollback.removedCandidateDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingURL.path))
        XCTAssertEqual(try Data(contentsOf: existingURL), existingBytes)
    }

    @MainActor
    func testProductionSingleSessionMediaRestorationRehearsalRejectsCorruptPreexistingCandidate() throws {
        let fixture = try makeActivationExecutionFixture()
        defer { tearDownActivationExecutionFixture(fixture) }
        let candidateID = UUID()
        let expectedBytes = Data("expected-candidate".utf8)
        let corruptBytes = Data("corrupt-candidate".utf8)
        let candidateURL = fixture.appState.productionSingleSessionMediaRestorationCandidateDirectoryURLForTests(
            propertyID: propertyID,
            sessionID: sessionID,
            candidateID: candidateID
        )
        try FileManager.default.createDirectory(at: candidateURL, withIntermediateDirectories: true)
        let existingURL = candidateURL.appendingPathComponent("duplicate.jpg", isDirectory: false)
        try corruptBytes.write(to: existingURL, options: .atomic)

        let rehearsal = fixture.appState.rehearseProductionSingleSessionMediaRestorationForTests(
            hydrationRehearsal: hydrationExecutionRehearsal(),
            candidateID: candidateID,
            mediaItems: [
                mediaRestorationItem(filename: "duplicate.jpg", data: expectedBytes)
            ],
            targetClassification: .localDev
        )

        XCTAssertEqual(rehearsal.state, .testOnlyMediaRestorationPartialFailureReported)
        XCTAssertEqual(rehearsal.restoredCount, 0)
        XCTAssertEqual(rehearsal.skippedExistingCount, 0)
        XCTAssertEqual(rehearsal.checksumMismatchCount, 1)
        XCTAssertEqual(rehearsal.failedCount, 1)
        XCTAssertEqual(rehearsal.acceptedCandidateMediaCount, 0)
        XCTAssertEqual(rehearsal.itemEvidence.first?.status, .rejectedChecksumMismatch)
        XCTAssertEqual(rehearsal.itemEvidence.first?.checksumVerifiedBeforeAcceptance, false)
        XCTAssertEqual(rehearsal.itemEvidence.first?.failureReason, "existing_candidate_checksum_mismatch")
        XCTAssertTrue(rehearsal.createdCandidateFilePaths.isEmpty)
        XCTAssertTrue(rehearsal.createdCandidateDirectoryPaths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: existingURL), corruptBytes)
    }

    @MainActor
    func testProductionSingleSessionMediaRestorationRehearsalRejectsChecksumMismatch() throws {
        let fixture = try makeActivationExecutionFixture()
        defer { tearDownActivationExecutionFixture(fixture) }
        let candidateID = UUID()
        let expected = Data("expected".utf8)
        let downloaded = Data("downloaded".utf8)

        let rehearsal = fixture.appState.rehearseProductionSingleSessionMediaRestorationForTests(
            hydrationRehearsal: hydrationExecutionRehearsal(),
            candidateID: candidateID,
            mediaItems: [
                mediaRestorationItem(filename: "mismatch.jpg", data: downloaded, expectedData: expected)
            ],
            targetClassification: .localDev
        )

        let candidateURL = fixture.appState.productionSingleSessionMediaRestorationCandidateDirectoryURLForTests(
            propertyID: propertyID,
            sessionID: sessionID,
            candidateID: candidateID
        )
        let rejectedURL = candidateURL.appendingPathComponent("mismatch.jpg", isDirectory: false)

        XCTAssertEqual(rehearsal.state, .testOnlyMediaRestorationPartialFailureReported)
        XCTAssertEqual(rehearsal.restoredCount, 0)
        XCTAssertEqual(rehearsal.checksumMismatchCount, 1)
        XCTAssertEqual(rehearsal.failedCount, 1)
        XCTAssertEqual(rehearsal.acceptedCandidateMediaCount, 0)
        XCTAssertTrue(rehearsal.partialFailureReported)
        XCTAssertEqual(rehearsal.itemEvidence.first?.status, .rejectedChecksumMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedURL.path))
    }

    @MainActor
    func testProductionSingleSessionMediaRestorationRehearsalReportsPartialFailurePerItem() throws {
        let fixture = try makeActivationExecutionFixture()
        defer { tearDownActivationExecutionFixture(fixture) }
        let candidateID = UUID()
        let goodBytes = Data("good-media".utf8)

        let rehearsal = fixture.appState.rehearseProductionSingleSessionMediaRestorationForTests(
            hydrationRehearsal: hydrationExecutionRehearsal(),
            candidateID: candidateID,
            mediaItems: [
                mediaRestorationItem(filename: "good.jpg", data: goodBytes),
                mediaRestorationItem(filename: "failed.jpg", data: nil, failureReason: "download_failed")
            ],
            targetClassification: .localDev
        )

        let goodEvidence = rehearsal.itemEvidence.first { $0.filename == "good.jpg" }
        let failedEvidence = rehearsal.itemEvidence.first { $0.filename == "failed.jpg" }
        let candidateURL = fixture.appState.productionSingleSessionMediaRestorationCandidateDirectoryURLForTests(
            propertyID: propertyID,
            sessionID: sessionID,
            candidateID: candidateID
        )
        let goodURL = candidateURL.appendingPathComponent("good.jpg", isDirectory: false)
        let failedURL = candidateURL.appendingPathComponent("failed.jpg", isDirectory: false)

        XCTAssertEqual(rehearsal.state, .testOnlyMediaRestorationPartialFailureReported)
        XCTAssertEqual(rehearsal.restoredCount, 1)
        XCTAssertEqual(rehearsal.failedCount, 1)
        XCTAssertEqual(rehearsal.acceptedCandidateMediaCount, 1)
        XCTAssertTrue(rehearsal.partialFailureReported)
        XCTAssertEqual(goodEvidence?.status, .restored)
        XCTAssertEqual(failedEvidence?.status, .failed)
        XCTAssertEqual(failedEvidence?.failureReason, "download_failed")
        XCTAssertEqual(try Data(contentsOf: goodURL), goodBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedURL.path))
    }

    @MainActor
    func testProductionSingleSessionMediaRestorationRollbackRemovesOnlyCandidateAndRestoresFingerprint() throws {
        let fixture = try makeActivationExecutionFixture()
        defer { tearDownActivationExecutionFixture(fixture) }
        let candidateID = UUID()
        let originalBytes = Data("pre-existing-original".utf8)
        let restoredBytes = Data("restored-copy".utf8)
        let originals = fixture.store.originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let originalURL = originals.appendingPathComponent("keep.jpg", isDirectory: false)
        try originalBytes.write(to: originalURL, options: .atomic)

        let rehearsal = fixture.appState.rehearseProductionSingleSessionMediaRestorationForTests(
            hydrationRehearsal: hydrationExecutionRehearsal(),
            candidateID: candidateID,
            mediaItems: [
                mediaRestorationItem(filename: "keep.jpg", data: restoredBytes)
            ],
            targetClassification: .localDev
        )
        let candidateURL = fixture.appState.productionSingleSessionMediaRestorationCandidateDirectoryURLForTests(
            propertyID: propertyID,
            sessionID: sessionID,
            candidateID: candidateID
        )
        let restoredURL = candidateURL.appendingPathComponent("keep.jpg", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertNotEqual(rehearsal.preRestorationFixtureFingerprint, rehearsal.postRestorationFixtureFingerprint)
        XCTAssertEqual(rehearsal.createdCandidateFilePaths, [restoredURL.path])
        XCTAssertTrue(rehearsal.createdCandidateDirectoryPaths.contains(candidateURL.path))
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)

        let rollback = fixture.appState.rollbackProductionSingleSessionMediaRestorationRehearsalForTests(
            rehearsal: rehearsal
        )

        XCTAssertEqual(rollback.state, .restoredPreRestorationFixture)
        XCTAssertTrue(rollback.blockers.isEmpty)
        XCTAssertTrue(rollback.removedCandidateDirectory)
        XCTAssertTrue(rollback.restoredPreRestorationFixture)
        XCTAssertEqual(rollback.preRestorationFixtureFingerprint, rollback.restoredFixtureFingerprint)
        XCTAssertTrue(rollback.existingOriginalsPreserved)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))

        let text = AppState.productionSingleSessionMediaRestorationRollbackReportText(rollback)
        XCTAssertTrue(text.contains("Production Single-Session Media Restoration Rollback"))
        XCTAssertTrue(text.contains("- media_restoration_rollback_state: restored_pre_restoration_fixture"))
        XCTAssertTrue(text.contains("removed only isolated rehearsal-created package-candidate media"))
    }

    @MainActor
    func testProductionSingleSessionMediaRestorationRehearsalGuardrailsBlockUnsafeRequests() throws {
        let fixture = try makeActivationExecutionFixture()
        defer { tearDownActivationExecutionFixture(fixture) }
        let candidateID = UUID()
        let bytes = Data("unsafe-request".utf8)

        let rehearsal = fixture.appState.rehearseProductionSingleSessionMediaRestorationForTests(
            hydrationRehearsal: hydrationExecutionRehearsal(),
            candidateID: candidateID,
            mediaItems: [
                mediaRestorationItem(filename: "blocked.jpg", data: bytes)
            ],
            targetClassification: .approvedProductionValidation,
            productionReadsEnabled: true,
            broadCanonicalReadRequired: true,
            remoteStateWriteAttempted: true,
            realLocalUserStateWriteAttempted: true,
            overwriteOriginalsAttempted: true,
            fallbackRetained: false,
            exportSealSyncMediaICloudBehaviorChanged: true
        )
        let candidateURL = fixture.appState.productionSingleSessionMediaRestorationCandidateDirectoryURLForTests(
            propertyID: propertyID,
            sessionID: sessionID,
            candidateID: candidateID
        )

        XCTAssertEqual(rehearsal.state, .blocked)
        XCTAssertTrue(rehearsal.blockers.contains("production_target_blocked"))
        XCTAssertTrue(rehearsal.blockers.contains("production_reads_must_remain_disabled"))
        XCTAssertTrue(rehearsal.blockers.contains("broad_canonical_read_requirement_blocked"))
        XCTAssertTrue(rehearsal.blockers.contains("remote_state_write_attempted"))
        XCTAssertTrue(rehearsal.blockers.contains("real_local_user_state_write_attempted"))
        XCTAssertTrue(rehearsal.blockers.contains("original_overwrite_attempted"))
        XCTAssertTrue(rehearsal.blockers.contains("local_fallback_unavailable"))
        XCTAssertTrue(rehearsal.blockers.contains("export_seal_sync_media_icloud_behavior_changed"))
        XCTAssertFalse(rehearsal.productionReadsBlocked)
        XCTAssertFalse(rehearsal.broadCanonicalReadBlocked)
        XCTAssertFalse(rehearsal.remoteStateWritesBlocked)
        XCTAssertFalse(rehearsal.realLocalUserStateWritesBlocked)
        XCTAssertFalse(rehearsal.originalsOverwriteBlocked)
        XCTAssertFalse(rehearsal.fallbackRetained)
        XCTAssertFalse(rehearsal.exportSealSyncMediaICloudUnchanged)
        XCTAssertEqual(rehearsal.acceptedCandidateMediaCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
    }

    @MainActor
    func testProductionValidationSelectedSessionActivationWithoutApprovalGateRemainsBlocked() throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment()
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let upload = rolloutReadinessDiagnostics()
        var diagnostics = fixture.appState._debugLocalDiagnosticsForTests()
        diagnostics.sessionSnapshotUpload = upload
        fixture.appState._debugSetLocalDiagnosticsForTests(diagnostics)

        let activation = fixture.appState.activateCanonicalCandidateForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_700),
            productionActivationGatePolicy: singleSessionGatePolicy()
        )

        XCTAssertEqual(fixture.appState.supabaseConfiguration.targetClassification, .approvedProductionValidation)
        XCTAssertFalse(activation.allowed)
        XCTAssertEqual(activation.activeSource, .local)
        XCTAssertEqual(activation.activationScope, "selected_session_only")
        XCTAssertTrue(activation.blockedReason?.contains("production_canonical_candidate_activation_blocked") == true)
        XCTAssertTrue(activation.blockedReason?.contains("operator_approval_missing") == true)
        XCTAssertTrue(activation.productionBlocked)
    }

    @MainActor
    func testProductionValidationSelectedSessionActivationWithExactAllowedGateActivatesDiagnosticScopeOnly() throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment()
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let upload = rolloutReadinessDiagnostics()
        let approval = approvedSingleSessionApproval(upload: upload)
        var diagnostics = fixture.appState._debugLocalDiagnosticsForTests()
        diagnostics.sessionSnapshotUpload = upload
        fixture.appState._debugSetLocalDiagnosticsForTests(diagnostics)

        let gate = fixture.appState.productionSingleSessionActivationGateForSelectedSession(
            policy: singleSessionGatePolicy(),
            approval: approval
        )
        let activation = fixture.appState.activateCanonicalCandidateForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_710),
            operatorApproval: approval,
            productionActivationGatePolicy: singleSessionGatePolicy()
        )
        let activatedDiagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertTrue(gate.gateAllowed)
        XCTAssertTrue(gate.exactScopeMatch)
        XCTAssertTrue(gate.operatorApprovalMatch)
        XCTAssertTrue(gate.productionWideDisabledConfirmed)
        XCTAssertTrue(activation.allowed)
        XCTAssertEqual(activation.activeSource, .canonicalCandidate)
        XCTAssertEqual(activation.rollbackSource, .local)
        XCTAssertEqual(activation.activationScope, "selected_session_only")
        XCTAssertEqual(activation.propertyID, propertyID)
        XCTAssertEqual(activation.sessionID, sessionID)
        XCTAssertTrue(activation.rollbackAvailable)
        XCTAssertTrue(activation.productionBlocked)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabasePropertyReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.mediaSupabaseUploadEnabled)
        XCTAssertFalse(activatedDiagnostics.lastCanonicalReadCandidateProductionWideEnabled)
        XCTAssertEqual(activatedDiagnostics.lastCanonicalCandidateActivationActiveSource, "canonical_candidate")
        XCTAssertEqual(activatedDiagnostics.lastCanonicalCandidateActivationScope, "selected_session_only")
        XCTAssertNil(activatedDiagnostics.lastHydrationAt)
        XCTAssertFalse(activatedDiagnostics.lastHydrationAllowed)
        XCTAssertNil(activatedDiagnostics.lastMediaRetrievalAt)
        XCTAssertFalse(activatedDiagnostics.lastMediaRetrievalAllowed)
        XCTAssertEqual(activatedDiagnostics.lastMediaRetrievalAttemptedCount, 0)
        XCTAssertEqual(activatedDiagnostics.attemptedCount, 0)
        XCTAssertFalse(activatedDiagnostics.lastStorageUploadCompleted)
        XCTAssertFalse(activatedDiagnostics.lastRowInsertCompleted)
    }

    @MainActor
    func testProductionValidationSelectedSessionActivationWrongApprovalScopeBlocks() throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment()
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let upload = rolloutReadinessDiagnostics()
        let wrongOrgID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let approval = approvedSingleSessionApproval(upload: upload, orgID: wrongOrgID)
        var diagnostics = fixture.appState._debugLocalDiagnosticsForTests()
        diagnostics.sessionSnapshotUpload = upload
        fixture.appState._debugSetLocalDiagnosticsForTests(diagnostics)

        let activation = fixture.appState.activateCanonicalCandidateForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_720),
            operatorApproval: approval,
            productionActivationGatePolicy: singleSessionGatePolicy()
        )

        XCTAssertFalse(activation.allowed)
        XCTAssertEqual(activation.activeSource, .local)
        XCTAssertTrue(activation.blockedReason?.contains("production_canonical_candidate_activation_blocked") == true)
        XCTAssertTrue(activation.blockedReason?.contains("exact_scope_match_required") == true)
    }

    @MainActor
    func testProductionValidationSelectedSessionActivationDisabledGateBlocks() throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment()
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let upload = rolloutReadinessDiagnostics()
        let approval = approvedSingleSessionApproval(upload: upload)
        var diagnostics = fixture.appState._debugLocalDiagnosticsForTests()
        diagnostics.sessionSnapshotUpload = upload
        fixture.appState._debugSetLocalDiagnosticsForTests(diagnostics)

        let activation = fixture.appState.activateCanonicalCandidateForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_730),
            operatorApproval: approval,
            productionActivationGatePolicy: singleSessionGatePolicy(enabled: false)
        )

        XCTAssertFalse(activation.allowed)
        XCTAssertEqual(activation.activeSource, .local)
        XCTAssertTrue(activation.blockedReason?.contains("production_canonical_candidate_activation_blocked") == true)
        XCTAssertTrue(activation.blockedReason?.contains("production_single_session_canonical_activation_disabled") == true)
    }

    @MainActor
    func testProductionValidationSelectedSessionActivationProductionWideReadsEnabledBlocks() throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment()
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let upload = rolloutReadinessDiagnostics(productionWideEnabled: true)
        let approval = approvedSingleSessionApproval(upload: upload)
        var diagnostics = fixture.appState._debugLocalDiagnosticsForTests()
        diagnostics.sessionSnapshotUpload = upload
        fixture.appState._debugSetLocalDiagnosticsForTests(diagnostics)

        let activation = fixture.appState.activateCanonicalCandidateForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_740),
            operatorApproval: approval,
            productionActivationGatePolicy: singleSessionGatePolicy()
        )

        XCTAssertFalse(activation.allowed)
        XCTAssertEqual(activation.activeSource, .local)
        XCTAssertTrue(activation.blockedReason?.contains("production_canonical_candidate_activation_blocked") == true)
        XCTAssertTrue(activation.blockedReason?.contains("production_wide_canonical_reads_not_disabled") == true)
    }

    @MainActor
    func testProductionValidationBlankLocalHealthStateBuildsSelectedScopeDiagnosticsAndOverlayWithPackageEvidence() async throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment()
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let report = passingPackageValidationReport()
        let initialDiagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertFalse(initialDiagnostics.lastCanonicalReadCandidateAllowed)
        XCTAssertFalse(initialDiagnostics.lastCanonicalCandidateOverlayAllowed)
        XCTAssertFalse(initialDiagnostics.lastCanonicalCandidateActivationAllowed)

        let readDiagnostics = await fixture.appState.runCanonicalReadDiagnosticsForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_750),
            productionValidationEvidence: report
        )
        let diagnosticsAfterRead = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        let overlay = await fixture.appState.buildCanonicalCandidateOverlayForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_760),
            productionValidationEvidence: report
        )
        let diagnosticsAfterOverlay = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertEqual(readDiagnostics.activeOrganizationID, orgID)
        XCTAssertEqual(readDiagnostics.propertyID, propertyID)
        XCTAssertEqual(readDiagnostics.sessionID, sessionID)
        XCTAssertTrue(diagnosticsAfterRead.lastCanonicalReadCandidateAllowed)
        XCTAssertEqual(diagnosticsAfterRead.lastCanonicalReadCandidateBlockedReason, "none")
        XCTAssertFalse(diagnosticsAfterRead.lastCanonicalReadCandidateProductionWideEnabled)
        XCTAssertTrue(overlay.allowed)
        XCTAssertEqual(overlay.overlay?.organizationID, orgID)
        XCTAssertEqual(overlay.overlay?.propertyID, propertyID)
        XCTAssertEqual(overlay.overlay?.sessionID, sessionID)
        XCTAssertEqual(overlay.overlay?.activeSource, "local")
        XCTAssertEqual(overlay.overlay?.fallbackSource, "local")
        XCTAssertEqual(diagnosticsAfterOverlay.lastCanonicalCandidateOverlayBlockedReason, "none")
        XCTAssertTrue(diagnosticsAfterOverlay.lastCanonicalCandidateOverlayAllowed)
        XCTAssertFalse(diagnosticsAfterOverlay.lastCanonicalCandidateActivationAllowed)
        XCTAssertEqual(diagnosticsAfterOverlay.lastCanonicalCandidateActivationActiveSource, "local")
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabasePropertyReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.mediaSupabaseUploadEnabled)
        XCTAssertNil(diagnosticsAfterOverlay.lastHydrationAt)
        XCTAssertFalse(diagnosticsAfterOverlay.lastHydrationAllowed)
        XCTAssertNil(diagnosticsAfterOverlay.lastMediaRetrievalAt)
        XCTAssertFalse(diagnosticsAfterOverlay.lastMediaRetrievalAllowed)
        XCTAssertEqual(diagnosticsAfterOverlay.attemptedCount, 0)
        XCTAssertFalse(diagnosticsAfterOverlay.lastStorageUploadCompleted)
        XCTAssertFalse(diagnosticsAfterOverlay.lastRowInsertCompleted)
    }

    @MainActor
    func testProductionValidationPackageReportPathExactSingletonCandidateAllowlistsAllowDiagnosticOverlay() async throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment(
                candidateOrgAllowlist: [orgID],
                candidatePropertyAllowlist: [propertyID],
                candidateSessionAllowlist: [sessionID]
            )
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let report = passingPackageValidationReport()

        let overlay = await fixture.appState.buildCanonicalCandidateOverlayForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_761),
            productionValidationEvidence: report
        )
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertTrue(overlay.allowed)
        XCTAssertEqual(overlay.overlay?.organizationID, orgID)
        XCTAssertEqual(overlay.overlay?.propertyID, propertyID)
        XCTAssertEqual(overlay.overlay?.sessionID, sessionID)
        XCTAssertEqual(overlay.overlay?.activeSource, "local")
        XCTAssertEqual(overlay.overlay?.fallbackSource, "local")
        XCTAssertTrue(overlay.rollbackAvailable)
        XCTAssertTrue(overlay.productionBlocked)
        XCTAssertEqual(diagnostics.lastCanonicalReadCandidateBlockedReason, "none")
        XCTAssertEqual(diagnostics.lastCanonicalCandidateOverlayBlockedReason, "none")
        XCTAssertTrue(diagnostics.lastCanonicalCandidateOverlayAllowed)
        XCTAssertFalse(diagnostics.lastCanonicalCandidateActivationAllowed)
        XCTAssertEqual(diagnostics.lastCanonicalCandidateActivationActiveSource, "local")
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabasePropertyReadEnabled)
        XCTAssertEqual(diagnostics.attemptedCount, 0)
        XCTAssertFalse(diagnostics.lastStorageUploadCompleted)
        XCTAssertFalse(diagnostics.lastRowInsertCompleted)
    }

    @MainActor
    func testProductionValidationPackageReportPathExtraOrgAllowlistBlocksDiagnosticOverlay() async throws {
        let extraOrgID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        try await assertPackageReportOverlayBlocksWithExtraCandidateAllowlist(
            environment: productionActivationExecutionEnvironment(
                candidateOrgAllowlist: [orgID, extraOrgID],
                candidatePropertyAllowlist: [propertyID],
                candidateSessionAllowlist: [sessionID]
            )
        )
    }

    @MainActor
    func testProductionValidationPackageReportPathExtraPropertyAllowlistBlocksDiagnosticOverlay() async throws {
        let extraPropertyID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        try await assertPackageReportOverlayBlocksWithExtraCandidateAllowlist(
            environment: productionActivationExecutionEnvironment(
                candidateOrgAllowlist: [orgID],
                candidatePropertyAllowlist: [propertyID, extraPropertyID],
                candidateSessionAllowlist: [sessionID]
            )
        )
    }

    @MainActor
    func testProductionValidationPackageReportPathExtraSessionAllowlistBlocksDiagnosticOverlay() async throws {
        let extraSessionID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        try await assertPackageReportOverlayBlocksWithExtraCandidateAllowlist(
            environment: productionActivationExecutionEnvironment(
                candidateOrgAllowlist: [orgID],
                candidatePropertyAllowlist: [propertyID],
                candidateSessionAllowlist: [sessionID, extraSessionID]
            )
        )
    }

    @MainActor
    func testProductionValidationDiagnosticOverlayBuildsWithoutApprovalWhenVerifiedReadEvidencePasses() async throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment()
        )
        defer { tearDownActivationExecutionFixture(fixture) }

        let overlay = await fixture.appState.buildCanonicalCandidateOverlayForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_755),
            productionValidationEvidence: nil
        )
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        let approval = fixture.appState.makeProductionSingleSessionOperatorApprovalForSelectedSession(
            approvedAt: Date(timeIntervalSinceReferenceDate: 9_756),
            expiresAt: Date(timeIntervalSinceReferenceDate: 9_856)
        )
        let activation = fixture.appState.activateCanonicalCandidateForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_757),
            operatorApproval: nil,
            productionActivationGatePolicy: singleSessionGatePolicy()
        )

        XCTAssertTrue(overlay.allowed)
        XCTAssertEqual(overlay.overlay?.organizationID, orgID)
        XCTAssertEqual(overlay.overlay?.propertyID, propertyID)
        XCTAssertEqual(overlay.overlay?.sessionID, sessionID)
        XCTAssertEqual(overlay.overlay?.activeSource, "local")
        XCTAssertEqual(overlay.overlay?.fallbackSource, "local")
        XCTAssertTrue(overlay.rollbackAvailable)
        XCTAssertTrue(overlay.productionBlocked)
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsResult, AppState.CanonicalReadDiagnosticResult.remoteMatchesLocal.rawValue)
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsVerifiedOrgID, orgID)
        XCTAssertTrue(diagnostics.lastCanonicalReadDiagnosticsCountParity == true)
        XCTAssertEqual(diagnostics.lastMissingChildCount, 0)
        XCTAssertTrue(diagnostics.lastCanonicalCandidateOverlayBuilt)
        XCTAssertTrue(diagnostics.lastCanonicalCandidateOverlayAllowed)
        XCTAssertEqual(diagnostics.lastCanonicalCandidateOverlayComparisonResult, AppState.CanonicalCandidateOverlayComparisonResult.candidateMatchesLocal.rawValue)
        XCTAssertEqual(diagnostics.lastCanonicalCandidateOverlayActiveSource, "local")
        XCTAssertTrue(diagnostics.lastCanonicalCandidateOverlayRollbackAvailable)
        XCTAssertEqual(approval.state, .approved)
        XCTAssertEqual(approval.approvedScope.orgID, orgID)
        XCTAssertEqual(approval.approvedScope.propertyID, propertyID)
        XCTAssertEqual(approval.approvedScope.sessionID, sessionID)
        XCTAssertFalse(activation.allowed)
        XCTAssertEqual(activation.activeSource, .local)
        XCTAssertTrue(activation.blockedReason?.contains("operator_approval_missing") == true)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabasePropertyReadEnabled)
        XCTAssertEqual(diagnostics.attemptedCount, 0)
        XCTAssertFalse(diagnostics.lastStorageUploadCompleted)
        XCTAssertFalse(diagnostics.lastRowInsertCompleted)
    }

    @MainActor
    func testProductionValidationDiagnosticOverlayWithoutPackageBlocksWhenReadEvidenceMissing() async throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment(),
            remoteOrgID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        defer { tearDownActivationExecutionFixture(fixture) }

        let overlay = await fixture.appState.buildCanonicalCandidateOverlayForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_758),
            productionValidationEvidence: nil
        )
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertFalse(overlay.allowed)
        XCTAssertNil(overlay.overlay)
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsResult, AppState.CanonicalReadDiagnosticResult.parentMismatch.rawValue)
        XCTAssertNil(diagnostics.lastCanonicalReadDiagnosticsVerifiedOrgID)
        XCTAssertFalse(diagnostics.lastCanonicalCandidateOverlayBuilt)
        XCTAssertFalse(diagnostics.lastCanonicalCandidateOverlayAllowed)
        XCTAssertTrue(diagnostics.lastCanonicalCandidateOverlayBlockedReason.contains("parent_org_or_property_divergence"))
        XCTAssertTrue(diagnostics.lastCanonicalCandidateOverlayBlockedReason.contains("production_canonical_candidate_overlay_blocked"))
        XCTAssertFalse(diagnostics.lastCanonicalCandidateActivationAllowed)
        XCTAssertEqual(diagnostics.lastCanonicalCandidateActivationActiveSource, "local")
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabasePropertyReadEnabled)
    }

    @MainActor
    func testProductionValidationDiagnosticOverlayWithoutPackageBlocksWrongAllowlistScope() async throws {
        var environment = productionActivationExecutionEnvironment()
        environment[SupabaseRuntimeConfiguration.canonicalReadCandidateSessionAllowlistEnvKey] = UUID(
            uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        )!.uuidString
        let fixture = try makeActivationExecutionFixture(
            environment: environment
        )
        defer { tearDownActivationExecutionFixture(fixture) }

        let overlay = await fixture.appState.buildCanonicalCandidateOverlayForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_759),
            productionValidationEvidence: nil
        )
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertFalse(overlay.allowed)
        XCTAssertNil(overlay.overlay)
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsVerifiedOrgID, orgID)
        XCTAssertFalse(diagnostics.lastCanonicalReadCandidateSessionAllowlisted)
        XCTAssertFalse(diagnostics.lastCanonicalCandidateOverlayAllowed)
        XCTAssertTrue(diagnostics.lastCanonicalCandidateOverlayBlockedReason.contains("session_not_allowlisted"))
        XCTAssertFalse(diagnostics.lastCanonicalCandidateActivationAllowed)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabasePropertyReadEnabled)
    }

    @MainActor
    func testReadDiagnosticsForDifferentScopeClearsStaleOverlayComparison() async throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment()
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let stalePropertyID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let staleSessionID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var diagnostics = fixture.appState._debugLocalDiagnosticsForTests()
        diagnostics.sessionSnapshotUpload.lastCanonicalReadDiagnosticsPropertyID = stalePropertyID
        diagnostics.sessionSnapshotUpload.lastCanonicalReadDiagnosticsSessionID = staleSessionID
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateOverlayBuilt = true
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateOverlayAllowed = true
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateOverlayPropertyID = stalePropertyID
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateOverlaySessionID = staleSessionID
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateOverlayComparisonResult = AppState.CanonicalCandidateOverlayComparisonResult.candidateIncomplete.rawValue
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateOverlayComparisonLocalShotCount = 10
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateOverlayComparisonRemoteShotCount = 10
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateOverlayComparisonLocalIssueObservationCount = 1
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateOverlayComparisonRemoteIssueObservationCount = 0
        diagnostics.sessionSnapshotUpload.lastCanonicalCandidateOverlayComparisonBlockedReason = "missing_remote_children"
        fixture.appState._debugSetLocalDiagnosticsForTests(diagnostics)

        let report = passingPackageValidationReport()
        _ = await fixture.appState.runCanonicalReadDiagnosticsForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_765),
            productionValidationEvidence: report
        )
        let refreshed = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertEqual(refreshed.lastCanonicalReadDiagnosticsPropertyID, propertyID)
        XCTAssertEqual(refreshed.lastCanonicalReadDiagnosticsSessionID, sessionID)
        XCTAssertEqual(refreshed.lastCanonicalReadDiagnosticsLocalIssueObservationCount, 0)
        XCTAssertEqual(refreshed.lastCanonicalReadDiagnosticsRemoteIssueObservationCount, 0)
        XCTAssertFalse(refreshed.lastCanonicalCandidateOverlayBuilt)
        XCTAssertFalse(refreshed.lastCanonicalCandidateOverlayAllowed)
        XCTAssertNil(refreshed.lastCanonicalCandidateOverlayPropertyID)
        XCTAssertNil(refreshed.lastCanonicalCandidateOverlaySessionID)
        XCTAssertEqual(refreshed.lastCanonicalCandidateOverlayComparisonResult, AppState.CanonicalCandidateOverlayComparisonResult.candidateUnavailable.rawValue)
        XCTAssertNil(refreshed.lastCanonicalCandidateOverlayComparisonLocalIssueObservationCount)
        XCTAssertNil(refreshed.lastCanonicalCandidateOverlayComparisonRemoteIssueObservationCount)
        XCTAssertEqual(refreshed.lastCanonicalCandidateOverlayComparisonBlockedReason, "not_checked")
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabasePropertyReadEnabled)
    }

    @MainActor
    func testProductionValidationWrongScopePackageEvidenceDoesNotUnblockDiagnosticsOrOverlay() async throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment()
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let wrongScope = AppState.ProductionCohortApprovalScope(
            orgID: orgID,
            propertyID: propertyID,
            sessionID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        )
        let report = passingPackageValidationReport(scope: wrongScope)

        _ = await fixture.appState.runCanonicalReadDiagnosticsForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_770),
            productionValidationEvidence: report
        )
        let diagnosticsAfterRead = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload
        let overlay = await fixture.appState.buildCanonicalCandidateOverlayForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_780),
            productionValidationEvidence: report
        )
        let diagnosticsAfterOverlay = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertFalse(diagnosticsAfterRead.lastCanonicalReadCandidateAllowed)
        XCTAssertTrue(
            diagnosticsAfterRead.lastCanonicalReadCandidateBlockedReason.contains(
                "production_canonical_read_candidate_requires_separate_explicit_approval"
            )
        )
        XCTAssertFalse(overlay.allowed)
        XCTAssertNil(overlay.overlay)
        XCTAssertTrue(overlay.activeSourceRemainsLocal)
        XCTAssertTrue(
            diagnosticsAfterOverlay.lastCanonicalCandidateOverlayBlockedReason.contains(
                "production_canonical_candidate_overlay_blocked"
            )
        )
        XCTAssertFalse(diagnosticsAfterOverlay.lastCanonicalCandidateActivationAllowed)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabasePropertyReadEnabled)
    }

    @MainActor
    func testProductionValidationOperatorApprovalRecordsExactScopeAfterEvidenceOverlayReady() async throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment()
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let report = passingPackageValidationReport()

        _ = await fixture.appState.runCanonicalReadDiagnosticsForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_790),
            productionValidationEvidence: report
        )
        _ = await fixture.appState.buildCanonicalCandidateOverlayForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_800),
            productionValidationEvidence: report
        )
        let approval = fixture.appState.makeProductionSingleSessionOperatorApprovalForSelectedSession(
            approvedAt: Date(timeIntervalSinceReferenceDate: 9_810),
            expiresAt: Date(timeIntervalSinceReferenceDate: 9_900)
        )
        let gate = fixture.appState.productionSingleSessionActivationGateForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_830),
            policy: singleSessionGatePolicy(),
            approval: approval
        )
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertEqual(approval.state, .approved)
        XCTAssertEqual(approval.approvedScope.orgID, orgID)
        XCTAssertEqual(approval.approvedScope.propertyID, propertyID)
        XCTAssertEqual(approval.approvedScope.sessionID, sessionID)
        XCTAssertTrue(gate.gateAllowed)
        XCTAssertTrue(gate.exactScopeMatch)
        XCTAssertTrue(gate.operatorApprovalMatch)
        XCTAssertTrue(gate.productionWideDisabledConfirmed)
        XCTAssertEqual(gate.selectedScope.orgID, orgID)
        XCTAssertEqual(gate.selectedScope.propertyID, propertyID)
        XCTAssertEqual(gate.selectedScope.sessionID, sessionID)
        XCTAssertEqual(gate.approvedScope.orgID, orgID)
        XCTAssertEqual(gate.approvedScope.propertyID, propertyID)
        XCTAssertEqual(gate.approvedScope.sessionID, sessionID)
        XCTAssertFalse(diagnostics.lastCanonicalCandidateActivationAllowed)
        XCTAssertEqual(diagnostics.lastCanonicalCandidateActivationActiveSource, "local")
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabasePropertyReadEnabled)
    }

    @MainActor
    func testProductionValidationNilActiveOrgDerivesSelectedScopeFromVerifiedPackageAndReadEvidence() async throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment(),
            activeOrganizationID: nil
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let report = passingPackageValidationReport()

        let read = await fixture.appState.runCanonicalReadDiagnosticsForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_840),
            productionValidationEvidence: report
        )
        let overlay = await fixture.appState.buildCanonicalCandidateOverlayForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_850),
            productionValidationEvidence: report
        )
        let approval = fixture.appState.makeProductionSingleSessionOperatorApprovalForSelectedSession(
            approvedAt: Date(timeIntervalSinceReferenceDate: 9_860),
            expiresAt: Date(timeIntervalSinceReferenceDate: 9_950)
        )
        let gate = fixture.appState.productionSingleSessionActivationGateForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_870),
            policy: singleSessionGatePolicy(),
            approval: approval
        )
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertNil(fixture.appState.activeOrganizationID)
        XCTAssertEqual(read.activeOrganizationID, orgID)
        XCTAssertEqual(read.verifiedOrganizationID, orgID)
        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsVerifiedOrgID, orgID)
        XCTAssertTrue(diagnostics.lastCanonicalReadCandidateAllowed)
        XCTAssertTrue(overlay.allowed)
        XCTAssertEqual(overlay.overlay?.organizationID, orgID)
        XCTAssertEqual(approval.state, .approved)
        XCTAssertEqual(approval.approvedScope.orgID, orgID)
        XCTAssertEqual(approval.approvedScope.propertyID, propertyID)
        XCTAssertEqual(approval.approvedScope.sessionID, sessionID)
        XCTAssertTrue(gate.gateAllowed)
        XCTAssertEqual(gate.selectedScope.orgID, orgID)
        XCTAssertEqual(gate.selectedScope.propertyID, propertyID)
        XCTAssertEqual(gate.selectedScope.sessionID, sessionID)
        XCTAssertEqual(gate.approvedScope.orgID, orgID)
        XCTAssertFalse(diagnostics.lastCanonicalCandidateActivationAllowed)
        XCTAssertEqual(diagnostics.lastCanonicalCandidateActivationActiveSource, "local")
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabasePropertyReadEnabled)
        XCTAssertEqual(diagnostics.attemptedCount, 0)
        XCTAssertFalse(diagnostics.lastStorageUploadCompleted)
        XCTAssertFalse(diagnostics.lastRowInsertCompleted)
    }

    @MainActor
    func testProductionValidationConflictingDerivedOrgEvidenceBlocksApprovalAndGate() async throws {
        let conflictingRemoteOrgID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment(),
            activeOrganizationID: nil,
            remoteOrgID: conflictingRemoteOrgID
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let report = passingPackageValidationReport()

        let read = await fixture.appState.runCanonicalReadDiagnosticsForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_880),
            productionValidationEvidence: report
        )
        let overlay = await fixture.appState.buildCanonicalCandidateOverlayForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_890),
            productionValidationEvidence: report
        )
        let approval = fixture.appState.makeProductionSingleSessionOperatorApprovalForSelectedSession(
            approvedAt: Date(timeIntervalSinceReferenceDate: 9_900),
            expiresAt: Date(timeIntervalSinceReferenceDate: 9_980)
        )
        let gate = fixture.appState.productionSingleSessionActivationGateForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_910),
            policy: singleSessionGatePolicy(),
            approval: approval
        )
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertEqual(read.result, .parentMismatch)
        XCTAssertNil(read.verifiedOrganizationID)
        XCTAssertNil(diagnostics.lastCanonicalReadDiagnosticsVerifiedOrgID)
        XCTAssertFalse(overlay.allowed)
        XCTAssertNil(overlay.overlay)
        XCTAssertEqual(approval.approvedScope.orgID, nil)
        XCTAssertTrue(approval.approvalBlockedReason?.contains("org_id_required") == true)
        XCTAssertFalse(gate.gateAllowed)
        XCTAssertNil(gate.selectedScope.orgID)
        XCTAssertTrue(gate.gateBlockedReason?.contains("exact_scope_match_required") == true)
        XCTAssertFalse(diagnostics.lastCanonicalCandidateActivationAllowed)
        XCTAssertEqual(diagnostics.lastCanonicalCandidateActivationActiveSource, "local")
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
    }

    @MainActor
    func testProductionValidationMissingParentConsistencyDoesNotDeriveApprovalOrg() throws {
        let fixture = try makeActivationExecutionFixture(
            environment: productionActivationExecutionEnvironment(),
            activeOrganizationID: nil
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        var diagnostics = fixture.appState._debugLocalDiagnosticsForTests()
        var upload = rolloutReadinessDiagnostics()
        upload.lastCanonicalReadDiagnosticsVerifiedOrgID = orgID
        upload.lastCanonicalReadDiagnosticsParentOrgConsistent = nil
        diagnostics.sessionSnapshotUpload = upload
        fixture.appState._debugSetLocalDiagnosticsForTests(diagnostics)

        let approval = fixture.appState.makeProductionSingleSessionOperatorApprovalForSelectedSession(
            approvedAt: Date(timeIntervalSinceReferenceDate: 9_920),
            expiresAt: Date(timeIntervalSinceReferenceDate: 9_990)
        )
        let gate = fixture.appState.productionSingleSessionActivationGateForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_930),
            policy: singleSessionGatePolicy(),
            approval: approval
        )

        XCTAssertNil(approval.approvedScope.orgID)
        XCTAssertTrue(approval.approvalBlockedReason?.contains("org_id_required") == true)
        XCTAssertFalse(gate.gateAllowed)
        XCTAssertNil(gate.selectedScope.orgID)
        XCTAssertTrue(gate.gateBlockedReason?.contains("exact_scope_match_required") == true)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
    }

    @MainActor
    func testProductionValidationNilActiveOrgWrongCandidateAllowlistStillBlocks() async throws {
        let wrongOrgID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var environment = productionActivationExecutionEnvironment()
        environment[SupabaseRuntimeConfiguration.canonicalReadCandidateOrgAllowlistEnvKey] = wrongOrgID.uuidString
        let fixture = try makeActivationExecutionFixture(
            environment: environment,
            activeOrganizationID: nil
        )
        defer { tearDownActivationExecutionFixture(fixture) }
        let report = passingPackageValidationReport()

        _ = await fixture.appState.runCanonicalReadDiagnosticsForSelectedSession(
            checkedAt: Date(timeIntervalSinceReferenceDate: 9_940),
            productionValidationEvidence: report
        )
        let diagnostics = fixture.appState._debugLocalDiagnosticsForTests().sessionSnapshotUpload

        XCTAssertEqual(diagnostics.lastCanonicalReadDiagnosticsVerifiedOrgID, orgID)
        XCTAssertFalse(diagnostics.lastCanonicalReadCandidateOrgAllowlisted)
        XCTAssertFalse(diagnostics.lastCanonicalReadCandidateAllowed)
        XCTAssertTrue(diagnostics.lastCanonicalReadCandidateBlockedReason.contains("org_not_allowlisted"))
        XCTAssertFalse(diagnostics.lastCanonicalCandidateActivationAllowed)
        XCTAssertEqual(diagnostics.lastCanonicalCandidateActivationActiveSource, "local")
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
    }

    func testProductionSingleSessionActivationGateDefaultFalseBlocksProduction() {
        let upload = rolloutReadinessDiagnostics()
        let approval = approvedSingleSessionApproval(upload: upload)

        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(enabled: false),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        XCTAssertFalse(gate.productionSingleSessionActivationGateEnabled)
        XCTAssertFalse(gate.gateAllowed)
        XCTAssertTrue(gate.gateBlockedReason?.contains("production_single_session_canonical_activation_disabled") == true)
    }

    func testProductionSingleSessionActivationGateMissingAllowlistBlocks() {
        let upload = rolloutReadinessDiagnostics()
        let approval = approvedSingleSessionApproval(upload: upload)

        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(orgAllowlist: [], propertyAllowlist: [], sessionAllowlist: []),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        XCTAssertFalse(gate.gateAllowed)
        XCTAssertFalse(gate.exactScopeMatch)
        XCTAssertTrue(gate.gateBlockedReason?.contains("exact_scope_match_required") == true)
    }

    func testProductionSingleSessionActivationGateApprovalMissingBlocks() {
        let upload = rolloutReadinessDiagnostics()

        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(),
            approval: nil,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        XCTAssertFalse(gate.gateAllowed)
        XCTAssertFalse(gate.operatorApprovalMatch)
        XCTAssertTrue(gate.gateBlockedReason?.contains("operator_approval_missing") == true)
    }

    func testProductionSingleSessionActivationGateApprovalWrongScopeBlocks() {
        let upload = rolloutReadinessDiagnostics()
        let wrongOrgID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let approval = approvedSingleSessionApproval(upload: upload, orgID: wrongOrgID)

        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        XCTAssertFalse(gate.gateAllowed)
        XCTAssertFalse(gate.exactScopeMatch)
        XCTAssertTrue(gate.gateBlockedReason?.contains("exact_scope_match_required") == true)
    }

    func testProductionSingleSessionActivationGateExpiredApprovalBlocks() {
        let upload = rolloutReadinessDiagnostics()
        let approval = approvedSingleSessionApproval(
            upload: upload,
            expiresAt: Date(timeIntervalSinceReferenceDate: 7_500),
            checkedAt: Date(timeIntervalSinceReferenceDate: 8_000)
        )

        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        XCTAssertFalse(gate.gateAllowed)
        XCTAssertFalse(gate.operatorApprovalMatch)
        XCTAssertTrue(gate.gateBlockedReason?.contains("operator_approval_expired") == true)
    }

    func testProductionSingleSessionActivationGateProductionWideEnabledBlocks() {
        let upload = rolloutReadinessDiagnostics(productionWideEnabled: true)
        let approval = approvedSingleSessionApproval(upload: upload)

        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        XCTAssertFalse(gate.gateAllowed)
        XCTAssertFalse(gate.productionWideDisabledConfirmed)
        XCTAssertTrue(gate.gateBlockedReason?.contains("production_wide_canonical_reads_not_disabled") == true)
    }

    func testProductionSingleSessionActivationGatePositiveExactScopeAllowsReadinessOnly() {
        let upload = rolloutReadinessDiagnostics()
        let approval = approvedSingleSessionApproval(upload: upload)

        let gate = AppState.makeProductionSingleSessionActivationGateDiagnostics(
            policy: singleSessionGatePolicy(),
            approval: approval,
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )
        let activation = AppState.makeCanonicalCandidateActivationResult(
            targetClassification: .approvedProductionValidation,
            diagnostics: upload,
            productionActivationGate: gate
        )

        XCTAssertTrue(gate.gateAllowed)
        XCTAssertTrue(gate.exactScopeMatch)
        XCTAssertTrue(gate.operatorApprovalMatch)
        XCTAssertTrue(gate.preflightPassed)
        XCTAssertTrue(gate.rollbackPreflightPassed)
        XCTAssertTrue(gate.productionWideDisabledConfirmed)
        XCTAssertNil(gate.gateBlockedReason)
        XCTAssertTrue(gate.noBehaviorChangedText.contains("does not activate production sessions"))
        XCTAssertTrue(activation.allowed)
        XCTAssertEqual(activation.activeSource, .canonicalCandidate)
        XCTAssertEqual(activation.activationScope, "selected_session_only")
        XCTAssertTrue(activation.productionBlocked)
    }

    func testProductionSingleSessionActivationGateLocalAndStagingBehaviorUnchanged() {
        let upload = rolloutReadinessDiagnostics()

        let localActivation = AppState.makeCanonicalCandidateActivationResult(
            targetClassification: .localDev,
            diagnostics: upload
        )
        let stagingActivation = AppState.makeCanonicalCandidateActivationResult(
            targetClassification: .approvedStaging,
            diagnostics: upload
        )
        let productionActivationWithoutGate = AppState.makeCanonicalCandidateActivationResult(
            targetClassification: .approvedProductionValidation,
            diagnostics: upload
        )

        XCTAssertTrue(localActivation.allowed)
        XCTAssertTrue(stagingActivation.allowed)
        XCTAssertFalse(productionActivationWithoutGate.allowed)
        XCTAssertTrue(productionActivationWithoutGate.blockedReason?.contains("production_canonical_candidate_activation_blocked") == true)
    }
}
