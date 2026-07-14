import XCTest
import CryptoKit
@testable import ScoutCapture

@MainActor
final class Phase2C27PSnapshotPackageHydrationParityValidationTests: XCTestCase {
    private struct PackageFixture {
        let suiteName: String
        let defaults: UserDefaults
        let storageRoot: URL
        let store: LocalStore
        let appState: AppState
        let orgID: UUID
        let property: Property
        let session: Session
        let snapshotID: UUID
        let row: AppState.SessionSnapshotUploadRow
        let object: AppState.SessionSnapshotStorageObject
        let sourceMetadata: SessionMetadata
        let mediaByPath: [String: Data]
    }

    private struct PackageEvidence {
        let fixture: PackageFixture
        let restore: AppState.SessionSnapshotRestoreDiagnosticsResult
        let hydration: AppState.SessionSnapshotHydrationResult
        let hydratedMetadata: SessionMetadata
        let mediaRetrieval: AppState.SessionSnapshotMediaRetrievalResult
        let mediaRestoration: AppState.ProductionSingleSessionMediaRestorationRehearsal
        let mediaRollback: AppState.ProductionSingleSessionMediaRestorationRollback
        let candidate: AppState.CanonicalReadCandidateDiagnostics
        let overlay: AppState.CanonicalCandidateOverlayBuildResult
        let comparison: AppState.CanonicalCandidateOverlayComparison
    }

    private struct FullyRestoredRollbackEvidence {
        let package: PackageEvidence
        let preHydrationFixtureFingerprint: String
        let restoredFixtureFingerprint: String
        let recoveredMediaArtifactsRemoved: Bool
        let packageCandidateArtifactsRemoved: Bool
        let originalSentinelPreservedDuringRestoration: Bool
        let validation: AppState.ProductionSingleSessionFullyRestoredPackageRollbackValidation
    }

    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C27P-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults() -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "ScoutCapture-2C27P-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")
        defaults.set(false, forKey: "sync_delta_enabled")
        defaults.set(true, forKey: "session_snapshot_shadow_write_enabled")
        return (suiteName, defaults)
    }

    private func localEnvironment(
        orgID: UUID,
        propertyID: UUID,
        sessionID: UUID,
        includeCandidateAllowlist: Bool = true
    ) -> [String: String] {
        var environment = [
            "SCOUTCAPTURE_SUPABASE_URL": "http://127.0.0.1:54321",
            "SCOUTCAPTURE_SUPABASE_ANON_KEY": "local-anon-key",
            SupabaseRuntimeConfiguration.canonicalReadCandidateEnabledEnvKey: "true"
        ]
        if includeCandidateAllowlist {
            environment[SupabaseRuntimeConfiguration.canonicalReadCandidateOrgAllowlistEnvKey] = orgID.uuidString
            environment[SupabaseRuntimeConfiguration.canonicalReadCandidatePropertyAllowlistEnvKey] = propertyID.uuidString
            environment[SupabaseRuntimeConfiguration.canonicalReadCandidateSessionAllowlistEnvKey] = sessionID.uuidString
        }
        return environment
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makePackageFixture(includeCandidateAllowlist: Bool = true) throws -> PackageFixture {
        let defaultsFixture = makeDefaults()
        let root = try makeTempStorageRoot()
        let store = LocalStore(testStorageRootURL: root)
        let orgID = UUID()
        _ = try store.createOrganization(Organization(id: orgID, name: "27P Package Org"))
        let property = try store.createProperty(Property(id: UUID(), orgId: orgID, name: "27P Package Property"))
        let session = try store.upsertSession(Session(
            id: UUID(),
            propertyID: property.id,
            startedAt: Date(timeIntervalSinceReferenceDate: 30_000),
            status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 30_600),
            exportedAt: nil,
            isSealed: true,
            firstDeliveredAt: nil,
            reExportExpiresAt: nil
        ))
        let firstMedia = Data("phase-2c-27p-first-media".utf8)
        let secondMedia = Data("phase-2c-27p-second-media".utf8)
        let firstShotID = UUID()
        let secondShotID = UUID()
        let issueID = UUID()
        let shots = [
            makeShot(
                id: firstShotID,
                propertyID: property.id,
                sessionID: session.id,
                filename: "phase-2c-27p-first.jpg",
                checksum: sha256Hex(firstMedia),
                byteSize: firstMedia.count,
                issueID: issueID
            ),
            makeShot(
                id: secondShotID,
                propertyID: property.id,
                sessionID: session.id,
                filename: "phase-2c-27p-second.jpg",
                checksum: sha256Hex(secondMedia),
                byteSize: secondMedia.count,
                issueID: nil
            )
        ]
        let issue = IssueMetadata(
            issueID: issueID,
            issueStatus: "active",
            currentReason: "27P package parity issue",
            firstSeenAt: Date(timeIntervalSinceReferenceDate: 30_100),
            lastSeenAt: Date(timeIntervalSinceReferenceDate: 30_200),
            lastCaptureSessionId: session.id,
            detailNote: "Real package parity validation",
            shotKey: shots[0].shotKey
        )
        let guided = GuidedShot(
            title: "27P guided checkpoint",
            building: "A",
            targetElevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            referenceImagePath: nil,
            shot: Shot(id: firstShotID, capturedAt: shots[0].createdAt),
            isCompleted: true
        )
        let sourceMetadata = SessionMetadata(
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
            shots: shots,
            issues: [issue],
            guidedShots: [guided]
        )
        try store.saveSessionMetadataAtomically(propertyID: property.id, sessionID: session.id, metadata: sourceMetadata)

        let environment = localEnvironment(
            orgID: orgID,
            propertyID: property.id,
            sessionID: session.id,
            includeCandidateAllowlist: includeCandidateAllowlist
        )
        let artifactAppState = AppState(
            localStore: store,
            userDefaults: makeDefaults().defaults,
            environment: environment,
            disableCloudBackupForTests: true
        )
        let snapshotID = UUID()
        let artifacts = try artifactAppState._debugMakeSessionSnapshotUploadArtifactsForTests(
            propertyID: property.id,
            sessionID: session.id,
            snapshotID: snapshotID,
            trigger: "phase_2c_27p_real_snapshot_package_fixture",
            generatedAt: Date(timeIntervalSinceReferenceDate: 30_700)
        )
        let mediaByPath = [
            shots[0].storagePath!: firstMedia,
            shots[1].storagePath!: secondMedia
        ]
        try store.deleteSession(id: session.id, propertyID: property.id)

        let row = artifacts.row
        let object = artifacts.object
        let appState = AppState(
            localStore: store,
            userDefaults: defaultsFixture.defaults,
            environment: environment,
            sessionSnapshotStorageUploadOverride: { _ in
                XCTFail("27P package validation must not upload session snapshots")
            },
            sessionSnapshotRowInsertOverride: { _ in
                XCTFail("27P package validation must not insert session snapshot rows")
            },
            sessionSnapshotRowsFetchOverride: { _, _, _ in [row] },
            sessionSnapshotStorageDownloadOverride: { _, _ in object.payloadData },
            sessionSnapshotMediaDownloadOverride: { _, path in
                guard let data = mediaByPath[path] else {
                    throw NSError(domain: "Phase2C27P", code: 1, userInfo: [NSLocalizedDescriptionKey: "media_payload_unavailable"])
                }
                return data
            },
            canonicalReadRemoteSnapshotFetchOverride: { _, requestedPropertyID, requestedSessionID in
                guard requestedPropertyID == nil || requestedPropertyID == property.id,
                      requestedSessionID == nil || requestedSessionID == session.id else {
                    return .unavailable
                }
                return AppState.CanonicalReadRemoteSnapshot(
                    properties: [
                        AppState.CanonicalReadRemotePropertyRow(
                            id: property.id,
                            orgID: orgID,
                            updatedAt: session.endedAt ?? session.startedAt,
                            revision: 1,
                            deletedAt: nil
                        )
                    ],
                    sessions: [
                        AppState.CanonicalReadRemoteSessionRow(
                            id: session.id,
                            orgID: orgID,
                            propertyID: property.id,
                            status: session.status.rawValue,
                            updatedAt: session.endedAt ?? session.startedAt,
                            revision: 1,
                            deletedAt: nil
                        )
                    ],
                    shots: sourceMetadata.shots.map {
                        AppState.CanonicalReadRemoteShotRow(id: $0.shotID, sessionID: session.id, deletedAt: nil)
                    },
                    observations: sourceMetadata.issues.map {
                        AppState.CanonicalReadRemoteObservationRow(
                            id: $0.issueID,
                            orgID: orgID,
                            propertyID: property.id,
                            sessionID: session.id,
                            status: $0.issueStatus,
                            updatedAt: $0.lastSeenAt,
                            deletedAt: nil
                        )
                    },
                    observationUpdates: []
                )
            },
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
        appState._debugSetOrganizationContextForTests(
            memberships: [ActiveOrganizationMembership(id: orgID, name: "27P Package Org", role: "owner")],
            activeOrganizationID: orgID,
            ready: true
        )
        appState._debugRefreshPropertiesLocallyForTests()
        appState.selectedPropertyID = property.id
        appState.currentSession = session

        return PackageFixture(
            suiteName: defaultsFixture.suiteName,
            defaults: defaultsFixture.defaults,
            storageRoot: root,
            store: store,
            appState: appState,
            orgID: orgID,
            property: property,
            session: session,
            snapshotID: snapshotID,
            row: row,
            object: object,
            sourceMetadata: sourceMetadata,
            mediaByPath: mediaByPath
        )
    }

    private func tearDownFixture(_ fixture: PackageFixture) {
        fixture.appState.shutdown()
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.storageRoot)
    }

    private func makeShot(
        id: UUID,
        propertyID: UUID,
        sessionID: UUID,
        filename: String,
        checksum: String,
        byteSize: Int,
        issueID: UUID?
    ) -> ShotMetadata {
        ShotMetadata(
            shotID: id,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 30_100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 30_200),
            building: "A",
            elevation: "North",
            detailType: filename,
            angleIndex: 1,
            shotKey: "a-north-\(filename)-1",
            isGuided: issueID != nil,
            isFlagged: issueID != nil,
            issueID: issueID,
            issueStatus: issueID == nil ? nil : "active",
            noteText: nil,
            noteCategory: nil,
            originalFilename: filename,
            originalRelativePath: "",
            originalByteSize: byteSize,
            storageBucket: "scoutcapture-originals",
            storagePath: "phase-2c-27p/\(sessionID.uuidString.lowercased())/\(filename)",
            checksumSHA256: checksum,
            byteSize: byteSize,
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
    }

    private func makeHydrationRehearsal(
        scope: AppState.ProductionCohortApprovalScope,
        restore: AppState.SessionSnapshotRestoreDiagnosticsResult,
        hydratedMetadata: SessionMetadata
    ) -> AppState.ProductionSingleSessionHydrationExecutionRehearsal {
        AppState.ProductionSingleSessionHydrationExecutionRehearsal(
            checkedAt: Date(timeIntervalSinceReferenceDate: 31_100),
            state: .testOnlyHydrationRehearsalPassed,
            blockers: [],
            blockedConditions: [
                "test_only_fixture_hydration_only",
                "production_reads_blocked",
                "remote_state_writes_blocked",
                "real_local_user_state_writes_blocked",
                "fallback_retained"
            ],
            hydrationReadinessScope: scope,
            restoreDiagnosticsScope: scope,
            preHydrationFixtureScope: scope,
            hydrationOperationScope: scope,
            postHydrationFixtureScope: scope,
            rollbackOperationScope: scope,
            restoredFixtureScope: scope,
            hydrationReadinessReviewOnly: true,
            exactSingleScopeSelected: true,
            scopesMatch: true,
            productionHydrationDisabled: true,
            executionTargetIsLocalTestFixture: true,
            productionTargetBlocked: true,
            productionReadsBlocked: true,
            remoteStateWritesBlocked: true,
            realLocalUserStateWritesBlocked: true,
            hydrationOperationSucceeded: true,
            postHydrationMatchesSnapshotEvidence: hydratedMetadata.shots.count == restore.snapshotShotCount &&
                hydratedMetadata.issues.count == restore.snapshotIssueCount &&
                hydratedMetadata.guidedShots.count == restore.snapshotGuidedCount,
            rollbackOperationSucceeded: true,
            rollbackRestoredPreHydrationFixture: true,
            fallbackRetained: true,
            noProductionBehaviorChangedText: "test-only 27P hydration rehearsal evidence"
        )
    }

    private func makeMediaRestorationItems(
        fixture: PackageFixture,
        hydratedMetadata: SessionMetadata,
        snapshotID: UUID
    ) throws -> [AppState.ProductionSingleSessionMediaRestorationItem] {
        let recoveredDirectory = fixture.appState.sessionSnapshotRecoveredMediaDirectoryURLForDiagnostics(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            snapshotID: snapshotID
        )
        return hydratedMetadata.shots.map { shot in
            let url = recoveredDirectory.appendingPathComponent(shot.originalFilename, isDirectory: false)
            return AppState.ProductionSingleSessionMediaRestorationItem(
                id: shot.shotID,
                originalFilename: shot.originalFilename,
                payloadData: try? Data(contentsOf: url),
                expectedChecksumSHA256: shot.checksumSHA256,
                failureReason: FileManager.default.fileExists(atPath: url.path) ? nil : "media_payload_unavailable"
            )
        }
    }

    private func fixtureFingerprint(_ fixture: PackageFixture) throws -> String {
        let sessions = try fixture.store.fetchSessions(propertyID: fixture.property.id)
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { session in
                [
                    session.id.uuidString,
                    session.propertyID.uuidString,
                    session.status.rawValue,
                    String(session.isSealed)
                ].joined(separator: ":")
            }
        let sessionRoot = fixture.store.sessionFolderURL(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        var lines = ["sessions:\(sessions.joined(separator: ","))"]
        if FileManager.default.fileExists(atPath: sessionRoot.path) {
            lines.append("session_root:present")
            let relativePaths = ((try? FileManager.default.subpathsOfDirectory(atPath: sessionRoot.path)) ?? [])
                .sorted()
            for relativePath in relativePaths {
                let url = sessionRoot.appendingPathComponent(relativePath, isDirectory: false)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      let data = try? Data(contentsOf: url) else {
                    continue
                }
                lines.append("\(relativePath):\(sha256Hex(data))")
            }
        } else {
            lines.append("session_root:missing")
        }
        return sha256Hex(Data(lines.joined(separator: "\n").utf8))
    }

    private func scope(for fixture: PackageFixture) -> AppState.ProductionCohortApprovalScope {
        AppState.ProductionCohortApprovalScope(
            orgID: fixture.orgID,
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
    }

    private func makeCandidateEvidence(
        fixture: PackageFixture,
        hydratedMetadata: SessionMetadata
    ) -> (
        candidate: AppState.CanonicalReadCandidateDiagnostics,
        overlay: AppState.CanonicalCandidateOverlayBuildResult,
        comparison: AppState.CanonicalCandidateOverlayComparison
    ) {
        let canonicalDiagnostics = AppState.CanonicalReadDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 31_200),
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            activeOrganizationID: fixture.orgID,
            result: .remoteMatchesLocal,
            remotePropertyFound: true,
            remoteSessionFound: true,
            localPropertyFound: true,
            localSessionFound: true,
            countParity: true,
            statusParity: true,
            parentOrgConsistent: true,
            parentPropertyConsistent: true,
            localShotCount: hydratedMetadata.shots.count,
            remoteShotCount: hydratedMetadata.shots.count,
            localIssueObservationCount: hydratedMetadata.issues.count,
            remoteIssueObservationCount: hydratedMetadata.issues.count,
            localGuidedCount: hydratedMetadata.guidedShots.count,
            remoteGuidedCount: hydratedMetadata.guidedShots.count,
            localUpdatedAt: hydratedMetadata.endedAt ?? hydratedMetadata.startedAt,
            remoteUpdatedAt: hydratedMetadata.endedAt ?? hydratedMetadata.startedAt,
            remoteRevision: 27,
            remoteFreshnessAgeSeconds: 0,
            canonicalRecommendation: "remote_candidate_after_replay_validation",
            blockedReason: nil,
            noBehaviorChangedText: "read only"
        )
        let parityReport = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: canonicalDiagnostics)
        let configuration = AppState.CanonicalReadCandidateConfiguration(
            enabled: true,
            orgAllowlist: [fixture.orgID],
            propertyAllowlist: [fixture.property.id],
            sessionAllowlist: [fixture.session.id],
            parityCompletenessThreshold: 0.95,
            mediaRecoveryConfidenceThreshold: 0.95
        )
        let candidate = AppState.makeCanonicalReadCandidateDiagnostics(
            checkedAt: Date(timeIntervalSinceReferenceDate: 31_300),
            configuration: configuration,
            targetClassification: .localDev,
            canonicalDiagnostics: canonicalDiagnostics,
            parityReport: parityReport,
            mediaRecoveryConfidence: 1
        )
        let overlay = AppState.buildCanonicalCandidateOverlayTestOnly(
            checkedAt: Date(timeIntervalSinceReferenceDate: 31_400),
            targetClassification: .localDev,
            canonicalDiagnostics: canonicalDiagnostics,
            parityReport: parityReport,
            candidateDiagnostics: candidate
        )
        let comparison = AppState.makeCanonicalCandidateOverlayComparison(
            checkedAt: Date(timeIntervalSinceReferenceDate: 31_500),
            canonicalDiagnostics: canonicalDiagnostics,
            overlayResult: overlay,
            parityReport: parityReport,
            localSessionStatus: hydratedMetadata.status.rawValue,
            remoteCandidateSessionStatus: hydratedMetadata.status.rawValue
        )
        return (candidate, overlay, comparison)
    }

    private func makePackageEvidence(includeCandidateAllowlist: Bool = true) async throws -> PackageEvidence {
        let fixture = try makePackageFixture(includeCandidateAllowlist: includeCandidateAllowlist)
        let restore = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()
        let hydration = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()
        let hydratedMetadata = try fixture.store.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let mediaRetrieval = await fixture.appState.retrieveSnapshotMediaTestOnly()
        let scope = AppState.ProductionCohortApprovalScope(
            orgID: fixture.orgID,
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let mediaItems = try makeMediaRestorationItems(
            fixture: fixture,
            hydratedMetadata: hydratedMetadata,
            snapshotID: fixture.snapshotID
        )
        let mediaRestoration = fixture.appState.rehearseProductionSingleSessionMediaRestorationForTests(
            hydrationRehearsal: makeHydrationRehearsal(
                scope: scope,
                restore: restore,
                hydratedMetadata: hydratedMetadata
            ),
            candidateID: UUID(),
            mediaItems: mediaItems,
            targetClassification: .localDev
        )
        let mediaRollback = fixture.appState.rollbackProductionSingleSessionMediaRestorationRehearsalForTests(
            rehearsal: mediaRestoration
        )
        let candidateEvidence = makeCandidateEvidence(fixture: fixture, hydratedMetadata: hydratedMetadata)
        return PackageEvidence(
            fixture: fixture,
            restore: restore,
            hydration: hydration,
            hydratedMetadata: hydratedMetadata,
            mediaRetrieval: mediaRetrieval,
            mediaRestoration: mediaRestoration,
            mediaRollback: mediaRollback,
            candidate: candidateEvidence.candidate,
            overlay: candidateEvidence.overlay,
            comparison: candidateEvidence.comparison
        )
    }

    private func packageReport(
        from evidence: PackageEvidence
    ) -> AppState.LocalHealthSessionSnapshotPackageValidationReport {
        let packageParity = validate(evidence)
        let rollback = AppState.makeProductionSingleSessionFullyRestoredPackageRollbackValidation(
            targetScope: scope(for: evidence.fixture),
            restoreDiagnostics: evidence.restore,
            hydration: evidence.hydration,
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            preHydrationFixtureFingerprint: "same",
            restoredFixtureFingerprint: "same",
            generatedRecoveredMediaArtifactsRemoved: true,
            generatedPackageCandidateArtifactsRemoved: true,
            originalsPreserved: true
        )
        return AppState.LocalHealthSessionSnapshotPackageValidationReport(
            checkedAt: Date(timeIntervalSinceReferenceDate: 41_600),
            targetScope: scope(for: evidence.fixture),
            snapshotID: evidence.fixture.snapshotID,
            packageParity: packageParity,
            fullyRestoredRollback: rollback,
            packageParityReportText: AppState.productionSingleSessionSnapshotPackageHydrationParityValidationReportText(packageParity),
            fullyRestoredRollbackReportText: AppState.productionSingleSessionFullyRestoredPackageRollbackValidationReportText(rollback),
            combinedReportText: "test package report"
        )
    }

    private func makeFullyRestoredRollbackEvidence() async throws -> FullyRestoredRollbackEvidence {
        let fixture = try makePackageFixture()
        let preHydrationFingerprint = try fixtureFingerprint(fixture)
        let restore = await fixture.appState.validateLatestSessionSnapshotRestoreDiagnostics()
        let hydration = await fixture.appState.hydrateMetadataFromLatestSessionSnapshot()
        let hydratedMetadata = try fixture.store.loadSessionMetadata(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id
        )
        let originalSentinelData = Data("phase-2c-27q-pre-existing-original".utf8)
        let originalSentinelURL = fixture.store
            .originalsFolderURL(propertyID: fixture.property.id, sessionID: fixture.session.id)
            .appendingPathComponent("phase-2c-27q-existing-original.jpg", isDirectory: false)
        try FileManager.default.createDirectory(
            at: originalSentinelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try originalSentinelData.write(to: originalSentinelURL, options: .atomic)

        let mediaRetrieval = await fixture.appState.retrieveSnapshotMediaTestOnly()
        let mediaItems = try makeMediaRestorationItems(
            fixture: fixture,
            hydratedMetadata: hydratedMetadata,
            snapshotID: fixture.snapshotID
        )
        let mediaRestoration = fixture.appState.rehearseProductionSingleSessionMediaRestorationForTests(
            hydrationRehearsal: makeHydrationRehearsal(
                scope: scope(for: fixture),
                restore: restore,
                hydratedMetadata: hydratedMetadata
            ),
            candidateID: UUID(),
            mediaItems: mediaItems,
            targetClassification: .localDev
        )
        let originalSentinelPreserved = (try? Data(contentsOf: originalSentinelURL)) == originalSentinelData
        let mediaRollback = fixture.appState.rollbackProductionSingleSessionMediaRestorationRehearsalForTests(
            rehearsal: mediaRestoration
        )
        try fixture.store.deleteSession(id: fixture.session.id, propertyID: fixture.property.id)

        let restoredFingerprint = try fixtureFingerprint(fixture)
        let recoveredMediaDirectory = fixture.appState.sessionSnapshotRecoveredMediaDirectoryURLForDiagnostics(
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            snapshotID: fixture.snapshotID
        )
        let recoveredRemoved = !FileManager.default.fileExists(atPath: recoveredMediaDirectory.path)
        let candidateRemoved = mediaRestoration.candidateDirectoryPath.map {
            !FileManager.default.fileExists(atPath: $0)
        } ?? false
        let candidateEvidence = makeCandidateEvidence(fixture: fixture, hydratedMetadata: hydratedMetadata)
        let package = PackageEvidence(
            fixture: fixture,
            restore: restore,
            hydration: hydration,
            hydratedMetadata: hydratedMetadata,
            mediaRetrieval: mediaRetrieval,
            mediaRestoration: mediaRestoration,
            mediaRollback: mediaRollback,
            candidate: candidateEvidence.candidate,
            overlay: candidateEvidence.overlay,
            comparison: candidateEvidence.comparison
        )
        let validation = AppState.makeProductionSingleSessionFullyRestoredPackageRollbackValidation(
            targetScope: scope(for: fixture),
            restoreDiagnostics: restore,
            hydration: hydration,
            mediaRetrieval: mediaRetrieval,
            mediaRestoration: mediaRestoration,
            mediaRollback: mediaRollback,
            preHydrationFixtureFingerprint: preHydrationFingerprint,
            restoredFixtureFingerprint: restoredFingerprint,
            generatedRecoveredMediaArtifactsRemoved: recoveredRemoved,
            generatedPackageCandidateArtifactsRemoved: candidateRemoved,
            originalsPreserved: originalSentinelPreserved
        )
        return FullyRestoredRollbackEvidence(
            package: package,
            preHydrationFixtureFingerprint: preHydrationFingerprint,
            restoredFixtureFingerprint: restoredFingerprint,
            recoveredMediaArtifactsRemoved: recoveredRemoved,
            packageCandidateArtifactsRemoved: candidateRemoved,
            originalSentinelPreservedDuringRestoration: originalSentinelPreserved,
            validation: validation
        )
    }

    private func validate(_ evidence: PackageEvidence) -> AppState.ProductionSingleSessionSnapshotPackageParityValidation {
        AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(
                orgID: evidence.fixture.orgID,
                propertyID: evidence.fixture.property.id,
                sessionID: evidence.fixture.session.id
            ),
            restoreDiagnostics: evidence.restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison
        )
    }

    private func canonicalDiagnostics(
        fixture: PackageFixture,
        result: AppState.CanonicalReadDiagnosticResult = .remoteMatchesLocal,
        localObservations: Int? = nil,
        remoteObservations: Int? = nil,
        localStatus: String? = nil,
        remoteStatus: String? = nil,
        parentOrgConsistent: Bool? = true,
        parentPropertyConsistent: Bool? = true
    ) -> AppState.CanonicalReadDiagnosticsResult {
        let localObservationCount = localObservations ?? fixture.sourceMetadata.issues.count
        let remoteObservationCount = remoteObservations ?? fixture.sourceMetadata.issues.count
        var diagnostics = AppState.CanonicalReadDiagnosticsResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 40_000),
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            activeOrganizationID: fixture.orgID,
            verifiedOrganizationID: fixture.orgID,
            result: result,
            remotePropertyFound: true,
            remoteSessionFound: true,
            localPropertyFound: true,
            localSessionFound: true,
            countParity: fixture.sourceMetadata.shots.count == fixture.sourceMetadata.shots.count && localObservationCount == remoteObservationCount,
            statusParity: (localStatus ?? fixture.session.status.rawValue) == (remoteStatus ?? fixture.session.status.rawValue),
            parentOrgConsistent: parentOrgConsistent,
            parentPropertyConsistent: parentPropertyConsistent,
            localShotCount: fixture.sourceMetadata.shots.count,
            remoteShotCount: fixture.sourceMetadata.shots.count,
            localIssueObservationCount: localObservationCount,
            remoteIssueObservationCount: remoteObservationCount,
            localGuidedCount: fixture.sourceMetadata.guidedShots.count,
            remoteGuidedCount: fixture.sourceMetadata.guidedShots.count,
            localUpdatedAt: fixture.session.endedAt ?? fixture.session.startedAt,
            localKnownStateAt: fixture.session.endedAt ?? fixture.session.startedAt,
            localKnownStateSource: "test",
            remoteUpdatedAt: fixture.session.endedAt ?? fixture.session.startedAt,
            remoteRevision: 1,
            remoteFreshnessAgeSeconds: 0,
            canonicalRecommendation: result == .remoteMatchesLocal ? "local_preferred_remote_verified" : "local_first_block_canonical_read",
            blockedReason: nil,
            noBehaviorChangedText: "test diagnostics"
        )
        diagnostics.localSessionStatus = localStatus ?? fixture.session.status.rawValue
        diagnostics.remoteSessionStatus = remoteStatus ?? fixture.session.status.rawValue
        return diagnostics
    }

    private func replayAction(
        fixture: PackageFixture,
        diagnosticsAfterReplay: AppState.CanonicalReadDiagnosticsResult?,
        failedCount: Int = 0,
        remoteNewerConflictCount: Int = 0,
        attemptedCount: Int = 2,
        upsertedCount: Int? = nil
    ) -> AppState.SelectedSessionFlaggedObservationReplayActionResult {
        AppState.SelectedSessionFlaggedObservationReplayActionResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 40_100),
            allowed: true,
            blockedReason: nil,
            orgID: fixture.orgID,
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            replayResult: AppState.NormalizedBackfillEntityResult(
                kind: .observation,
                attemptedCount: attemptedCount,
                upsertedCount: upsertedCount ?? (failedCount == 0 ? attemptedCount : max(attemptedCount - 1, 0)),
                skippedCount: 0,
                failedCount: failedCount,
                remoteNewerConflictCount: remoteNewerConflictCount,
                message: failedCount == 0 ? "observation_updates_inserted" : "observation_replay_failed"
            ),
            diagnosticsAfterReplay: diagnosticsAfterReplay,
            noBehaviorChangedText: "test observation replay"
        )
    }

    private func lifecycleAction(
        fixture: PackageFixture,
        diagnosticsAfterReplay: AppState.CanonicalReadDiagnosticsResult?,
        failedCount: Int = 0,
        remoteNewerConflictCount: Int = 0
    ) -> AppState.SelectedSessionLifecycleReplayActionResult {
        AppState.SelectedSessionLifecycleReplayActionResult(
            checkedAt: Date(timeIntervalSinceReferenceDate: 40_200),
            allowed: true,
            blockedReason: nil,
            orgID: fixture.orgID,
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            replayResult: AppState.NormalizedBackfillEntityResult(
                kind: .session,
                attemptedCount: 1,
                upsertedCount: failedCount == 0 ? 1 : 0,
                skippedCount: 0,
                failedCount: failedCount,
                remoteNewerConflictCount: remoteNewerConflictCount,
                message: failedCount == 0 ? "session_lifecycle_updated" : "lifecycle_replay_failed"
            ),
            diagnosticsAfterReplay: diagnosticsAfterReplay,
            noBehaviorChangedText: "test lifecycle replay"
        )
    }

    private func normalizedResult(
        kind: AppState.NormalizedBackfillEntityKind,
        attemptedCount: Int,
        upsertedCount: Int,
        failedCount: Int = 0,
        remoteNewerConflictCount: Int = 0
    ) -> AppState.NormalizedBackfillEntityResult {
        AppState.NormalizedBackfillEntityResult(
            kind: kind,
            attemptedCount: attemptedCount,
            upsertedCount: upsertedCount,
            skippedCount: 0,
            failedCount: failedCount,
            remoteNewerConflictCount: remoteNewerConflictCount,
            message: failedCount == 0 ? "ok" : "failed"
        )
    }

    private func runtimePipelineContext(
        fixture: PackageFixture,
        authorization: AppState.RuntimeSelectedSessionQAAuthorizationStatus
    ) throws -> AppState.SelectedSessionValidationPipelineAuthorizationContext {
        AppState.SelectedSessionValidationPipelineAuthorizationContext(
            orgID: try XCTUnwrap(authorization.authorizedScope.orgID),
            propertyID: try XCTUnwrap(authorization.authorizedScope.propertyID),
            sessionID: try XCTUnwrap(authorization.authorizedScope.sessionID),
            authorizedAt: try XCTUnwrap(authorization.authorizedAt),
            expiresAt: try XCTUnwrap(authorization.expiresAt)
        )
    }

    private func overlayEvidence(
        fixture: PackageFixture,
        diagnostics: AppState.CanonicalReadDiagnosticsResult,
        comparisonResult: AppState.CanonicalCandidateOverlayComparisonResult = .candidateMatchesLocal,
        comparisonBlockedReason: String? = nil
    ) -> (
        candidate: AppState.CanonicalReadCandidateDiagnostics,
        overlay: AppState.CanonicalCandidateOverlayBuildResult,
        comparison: AppState.CanonicalCandidateOverlayComparison
    ) {
        let parityReport = AppState.makeNormalizedParityGapReport(canonicalDiagnostics: diagnostics)
        let candidate = AppState.makeCanonicalReadCandidateDiagnostics(
            checkedAt: Date(timeIntervalSinceReferenceDate: 40_300),
            configuration: AppState.CanonicalReadCandidateConfiguration(
                enabled: true,
                orgAllowlist: [fixture.orgID],
                propertyAllowlist: [fixture.property.id],
                sessionAllowlist: [fixture.session.id],
                parityCompletenessThreshold: 0.95,
                mediaRecoveryConfidenceThreshold: 0.95
            ),
            targetClassification: .localDev,
            canonicalDiagnostics: diagnostics,
            parityReport: parityReport,
            mediaRecoveryConfidence: 1,
            productionValidationEvidenceReady: true
        )
        let overlay = AppState.buildCanonicalCandidateOverlayTestOnly(
            checkedAt: Date(timeIntervalSinceReferenceDate: 40_400),
            targetClassification: .localDev,
            canonicalDiagnostics: diagnostics,
            parityReport: parityReport,
            candidateDiagnostics: candidate,
            productionValidationEvidenceReady: true
        )
        let comparison = AppState.CanonicalCandidateOverlayComparison(
            checkedAt: Date(timeIntervalSinceReferenceDate: 40_500),
            result: comparisonResult,
            propertyID: fixture.property.id,
            sessionID: fixture.session.id,
            localSessionStatus: diagnostics.localSessionStatus,
            remoteCandidateSessionStatus: diagnostics.remoteSessionStatus,
            localShotCount: diagnostics.localShotCount,
            remoteCandidateShotCount: diagnostics.remoteShotCount,
            localIssueObservationCount: diagnostics.localIssueObservationCount,
            remoteCandidateIssueObservationCount: diagnostics.remoteIssueObservationCount,
            localUpdatedAt: diagnostics.localUpdatedAt,
            remoteCandidateUpdatedAt: diagnostics.remoteUpdatedAt,
            parityConfidence: comparisonResult == .candidateMatchesLocal ? 1 : 0.5,
            fallbackSource: "local",
            activeSource: "local",
            overlaySource: "remote_normalized_candidate_with_local_fallback",
            rollbackAvailable: true,
            trustedReason: comparisonResult == .candidateMatchesLocal ? "test_match" : "test_mismatch",
            blockedReason: comparisonBlockedReason,
            noBehaviorChangedText: "test overlay comparison"
        )
        return (candidate, overlay, comparison)
    }

    private func assertPipelineDidNotEnableProductionBehavior(
        _ fixture: PackageFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled, file: file, line: line)
        XCTAssertFalse(
            fixture.appState.localDiagnostics.sessionSnapshotUpload.lastCanonicalReadCandidateProductionWideEnabled,
            file: file,
            line: line
        )
        XCTAssertFalse(
            fixture.appState.localDiagnostics.sessionSnapshotUpload.lastCanonicalCandidateActivationAllowed,
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.appState.localDiagnostics.sessionSnapshotUpload.lastCanonicalCandidateActivationActiveSource,
            "local",
            file: file,
            line: line
        )
    }

    func testRealSnapshotPackageHydrationParityPositivePath() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }

        let validation = validate(evidence)

        XCTAssertEqual(evidence.restore.result, .restorableMetadataCandidate)
        XCTAssertTrue(evidence.restore.checksumVerified)
        XCTAssertTrue(evidence.restore.rowObjectVerified)
        XCTAssertTrue(evidence.restore.parentRemoteVerified)
        XCTAssertEqual(evidence.restore.snapshotSchemaVersion, 1)
        XCTAssertNotEqual(evidence.restore.freshness, "local_newer")
        XCTAssertTrue(evidence.hydration.allowed)
        XCTAssertEqual(evidence.hydratedMetadata.shots.count, evidence.fixture.sourceMetadata.shots.count)
        XCTAssertEqual(evidence.hydratedMetadata.issues.count, evidence.fixture.sourceMetadata.issues.count)
        XCTAssertEqual(evidence.hydratedMetadata.guidedShots.count, evidence.fixture.sourceMetadata.guidedShots.count)
        XCTAssertTrue(evidence.mediaRetrieval.allowed)
        XCTAssertEqual(evidence.mediaRetrieval.downloadedCount, evidence.fixture.sourceMetadata.shots.count)
        XCTAssertEqual(evidence.mediaRetrieval.failedCount, 0)
        XCTAssertEqual(evidence.mediaRestoration.state, .testOnlyMediaRestorationRehearsalPassed)
        XCTAssertEqual(evidence.mediaRestoration.acceptedCandidateMediaCount, evidence.fixture.sourceMetadata.shots.count)
        XCTAssertTrue(evidence.mediaRestoration.existingOriginalsPreserved)
        XCTAssertEqual(evidence.mediaRollback.state, .restoredPreRestorationFixture)
        XCTAssertEqual(validation.state, .testOnlyPackageParityPassed)
        XCTAssertTrue(validation.blockers.isEmpty)
        XCTAssertTrue(validation.fallbackRetained)
        XCTAssertTrue(validation.activeSourceRemainsLocal)
        XCTAssertTrue(validation.productionReadsBlocked)
        XCTAssertTrue(validation.remoteStateWritesBlocked)
        XCTAssertTrue(validation.realLocalUserStateWritesBlocked)
        XCTAssertTrue(validation.originalsOverwriteBlocked)
        XCTAssertTrue(validation.rollbackCleanupVerified)

        let report = AppState.productionSingleSessionSnapshotPackageHydrationParityValidationReportText(validation)
        XCTAssertTrue(report.contains("Production Single-Session Snapshot Package Hydration Parity Validation"))
        XCTAssertTrue(report.contains("- package_parity_state: test_only_package_parity_passed"))
        XCTAssertTrue(report.contains("No production behavior changed"))
    }

    func testLocalHealthOperatorPackageValidationProducesCopyableReports() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }

        let report = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()

        XCTAssertEqual(AppState.localHealthSessionSnapshotPackageValidationActionTitle, "Run Package Parity / Rollback Validation")
        XCTAssertEqual(report.snapshotID, fixture.snapshotID)
        XCTAssertEqual(report.packageParity.state, .testOnlyPackageParityPassed)
        XCTAssertEqual(report.fullyRestoredRollback.state, .testOnlyFullyRestoredPackageRollbackPassed)
        XCTAssertTrue(report.packageParity.blockers.isEmpty)
        XCTAssertTrue(report.fullyRestoredRollback.blockers.isEmpty)
        XCTAssertTrue(report.packageParityReportText.contains("Production Single-Session Snapshot Package Hydration Parity Validation"))
        XCTAssertTrue(report.fullyRestoredRollbackReportText.contains("Production Single-Session Fully Restored Package Rollback Validation"))
        XCTAssertTrue(report.combinedReportText.contains("- package_parity_state: test_only_package_parity_passed"))
        XCTAssertTrue(report.combinedReportText.contains("- package_rollback_state: test_only_fully_restored_package_rollback_passed"))
        XCTAssertTrue(report.combinedReportText.contains("- supabase_read_enabled: false"))
        XCTAssertTrue(report.combinedReportText.contains("- activation_performed: false"))
        XCTAssertTrue(report.combinedReportText.contains("- remote_writes_performed: false"))
    }

    func testLocalHealthOperatorPackageValidationRequiresSelectedScope() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        fixture.appState.selectedPropertyID = nil
        fixture.appState.currentSession = nil

        let report = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()

        XCTAssertEqual(report.packageParity.state, .blocked)
        XCTAssertEqual(report.fullyRestoredRollback.state, .blocked)
        XCTAssertFalse(report.packageParity.blockers.isEmpty)
        XCTAssertFalse(report.fullyRestoredRollback.blockers.isEmpty)
        XCTAssertTrue(report.combinedReportText.contains("selected_session_snapshot_target_required"))
        XCTAssertTrue(report.combinedReportText.contains("- activation_performed: false"))
    }

    func testLocalHealthOperatorPackageValidationBlocksMissingSnapshot() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let appState = AppState(
            localStore: fixture.store,
            userDefaults: fixture.defaults,
            environment: localEnvironment(orgID: fixture.orgID, propertyID: fixture.property.id, sessionID: fixture.session.id),
            sessionSnapshotStorageUploadOverride: { _ in
                XCTFail("Local Health package validation must not upload session snapshots")
            },
            sessionSnapshotRowInsertOverride: { _ in
                XCTFail("Local Health package validation must not insert session snapshot rows")
            },
            sessionSnapshotRowsFetchOverride: { _, _, _ in [] },
            sessionSnapshotStorageDownloadOverride: { _, _ in
                XCTFail("Missing snapshot should not download snapshot payload")
                return Data()
            },
            sessionSnapshotMediaDownloadOverride: { _, _ in
                XCTFail("Missing snapshot should not download media")
                return Data()
            },
            sessionSnapshotRemoteParentPreflightOverride: { _, _, _ in
                AppState.SessionSnapshotAuthPreflightRemoteParentStatus(
                    propertyExists: true,
                    sessionExists: true,
                    propertyOrgID: fixture.orgID,
                    sessionOrgID: fixture.orgID,
                    sessionPropertyIDMatches: true,
                    orgIDsMatch: true,
                    errorMessage: nil
                )
            },
            disableCloudBackupForTests: true
        )
        defer { appState.shutdown() }
        appState._debugSetOrganizationContextForTests(
            memberships: [ActiveOrganizationMembership(id: fixture.orgID, name: "27P Package Org", role: "owner")],
            activeOrganizationID: fixture.orgID,
            ready: true
        )
        appState.selectedPropertyID = fixture.property.id
        appState.currentSession = fixture.session

        let report = await appState.runLocalHealthSelectedSessionSnapshotPackageValidation()

        XCTAssertEqual(report.packageParity.state, .blocked)
        XCTAssertEqual(report.fullyRestoredRollback.state, .blocked)
        XCTAssertTrue(report.packageParity.blockers.contains("restore_diagnostics_not_restorable"))
        XCTAssertTrue(report.fullyRestoredRollback.blockers.contains("restore_diagnostics_not_restorable"))
        XCTAssertNil(report.snapshotID)
        XCTAssertTrue(report.combinedReportText.contains("- remote_writes_performed: false"))
    }

    func testFullyRestoredPackageRollbackRestoresPreHydrationFixture() async throws {
        let evidence = try await makeFullyRestoredRollbackEvidence()
        defer { tearDownFixture(evidence.package.fixture) }

        let validation = evidence.validation

        XCTAssertEqual(evidence.package.restore.result, .restorableMetadataCandidate)
        XCTAssertTrue(evidence.package.hydration.allowed)
        XCTAssertEqual(evidence.package.mediaRestoration.state, .testOnlyMediaRestorationRehearsalPassed)
        XCTAssertEqual(evidence.package.mediaRollback.state, .restoredPreRestorationFixture)
        XCTAssertEqual(evidence.preHydrationFixtureFingerprint, evidence.restoredFixtureFingerprint)
        XCTAssertTrue(evidence.recoveredMediaArtifactsRemoved)
        XCTAssertTrue(evidence.packageCandidateArtifactsRemoved)
        XCTAssertTrue(evidence.originalSentinelPreservedDuringRestoration)
        XCTAssertEqual(validation.state, .testOnlyFullyRestoredPackageRollbackPassed)
        XCTAssertTrue(validation.blockers.isEmpty)
        XCTAssertTrue(validation.preHydrationLocalFixtureRestored)
        XCTAssertTrue(validation.generatedRecoveredMediaArtifactsRemoved)
        XCTAssertTrue(validation.generatedPackageCandidateArtifactsRemoved)
        XCTAssertTrue(validation.originalsPreserved)
        XCTAssertTrue(validation.fallbackRetained)
        XCTAssertTrue(validation.activeSourceRemainsLocal)
        XCTAssertTrue(validation.productionReadsBlocked)
        XCTAssertTrue(validation.broadCanonicalReadsBlocked)
        XCTAssertTrue(validation.activationBlocked)
        XCTAssertTrue(validation.remoteStateWritesBlocked)
        XCTAssertTrue(validation.realLocalUserStateWritesBlocked)
        XCTAssertTrue(validation.exportSealSyncMediaICloudUnchanged)
        XCTAssertTrue(validation.schemaRLSDataUnchanged)

        let report = AppState.productionSingleSessionFullyRestoredPackageRollbackValidationReportText(validation)
        XCTAssertTrue(report.contains("Production Single-Session Fully Restored Package Rollback Validation"))
        XCTAssertTrue(report.contains("- package_rollback_state: test_only_fully_restored_package_rollback_passed"))
        XCTAssertTrue(report.contains("No production behavior changed"))
    }

    func testFullyRestoredPackageRollbackValidationBlocksUnsafeOrIncompleteRollback() async throws {
        let evidence = try await makeFullyRestoredRollbackEvidence()
        defer { tearDownFixture(evidence.package.fixture) }
        var restore = evidence.package.restore
        restore.result = .parentMismatch
        restore.parentRemoteVerified = false
        restore.freshness = "local_newer"
        restore.checksumVerified = false
        let failedItem = AppState.SessionSnapshotMediaRetrievalItemResult(
            id: evidence.package.fixture.sourceMetadata.shots[0].shotID,
            status: .failed,
            checksumVerified: false,
            recoveredLocalPathPresent: false,
            failureReason: "media_payload_unavailable"
        )
        let retrieval = AppState.SessionSnapshotMediaRetrievalResult(
            retrievedAt: evidence.package.mediaRetrieval.retrievedAt,
            allowed: true,
            blockedReason: nil,
            propertyID: evidence.package.mediaRetrieval.propertyID,
            sessionID: evidence.package.mediaRetrieval.sessionID,
            snapshotID: evidence.package.mediaRetrieval.snapshotID,
            attemptedCount: evidence.package.mediaRetrieval.attemptedCount,
            downloadedCount: evidence.package.mediaRetrieval.downloadedCount - 1,
            checksumVerifiedCount: evidence.package.mediaRetrieval.checksumVerifiedCount - 1,
            skippedExistingCount: evidence.package.mediaRetrieval.skippedExistingCount,
            failedCount: 1,
            recoveredLocalPathCount: evidence.package.mediaRetrieval.recoveredLocalPathCount - 1,
            recoveredMediaDirectoryPathPresent: evidence.package.mediaRetrieval.recoveredMediaDirectoryPathPresent,
            items: [failedItem]
        )

        let validation = AppState.makeProductionSingleSessionFullyRestoredPackageRollbackValidation(
            targetScope: scope(for: evidence.package.fixture),
            restoreDiagnostics: restore,
            hydration: evidence.package.hydration,
            mediaRetrieval: retrieval,
            mediaRestoration: evidence.package.mediaRestoration,
            mediaRollback: evidence.package.mediaRollback,
            preHydrationFixtureFingerprint: evidence.preHydrationFixtureFingerprint,
            restoredFixtureFingerprint: "wrong-fingerprint",
            generatedRecoveredMediaArtifactsRemoved: false,
            generatedPackageCandidateArtifactsRemoved: false,
            originalsPreserved: false,
            fallbackRetained: false,
            activeSource: .canonicalCandidate,
            productionReadsEnabled: true,
            broadCanonicalReadRequired: true,
            activationAttempted: true,
            remoteStateWriteAttempted: true,
            realLocalUserStateWriteAttempted: true,
            exportSealSyncMediaICloudBehaviorChanged: true,
            schemaRLSDataBehaviorChanged: true
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("metadata_rollback_mismatch"))
        XCTAssertTrue(validation.blockers.contains("leftover_recovered_media_artifacts"))
        XCTAssertTrue(validation.blockers.contains("leftover_candidate_artifacts"))
        XCTAssertTrue(validation.blockers.contains("original_overwrite"))
        XCTAssertTrue(validation.blockers.contains("fallback_missing"))
        XCTAssertTrue(validation.blockers.contains("unsafe_read_write_activation_attempt"))
        XCTAssertTrue(validation.blockers.contains("parent_mismatch"))
        XCTAssertTrue(validation.blockers.contains("local_newer_freshness"))
        XCTAssertTrue(validation.blockers.contains("missing_media"))
        XCTAssertTrue(validation.blockers.contains("checksum_mismatch"))
    }

    func testPackageParityValidationBlocksChecksumMismatch() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }
        var restore = evidence.restore
        restore.result = .checksumFailed
        restore.checksumVerified = false

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: evidence.fixture.property.id, sessionID: evidence.fixture.session.id),
            restoreDiagnostics: restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("checksum_mismatch"))
        XCTAssertTrue(validation.blockers.contains("snapshot_package_integrity_not_verified"))
    }

    func testPackageParityValidationBlocksMissingMedia() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }
        let failedItem = AppState.SessionSnapshotMediaRetrievalItemResult(
            id: evidence.fixture.sourceMetadata.shots[0].shotID,
            status: .failed,
            checksumVerified: false,
            recoveredLocalPathPresent: false,
            failureReason: "media_payload_unavailable"
        )
        let retrieval = AppState.SessionSnapshotMediaRetrievalResult(
            retrievedAt: evidence.mediaRetrieval.retrievedAt,
            allowed: true,
            blockedReason: nil,
            propertyID: evidence.mediaRetrieval.propertyID,
            sessionID: evidence.mediaRetrieval.sessionID,
            snapshotID: evidence.mediaRetrieval.snapshotID,
            attemptedCount: evidence.mediaRetrieval.attemptedCount,
            downloadedCount: evidence.mediaRetrieval.downloadedCount - 1,
            checksumVerifiedCount: evidence.mediaRetrieval.checksumVerifiedCount - 1,
            skippedExistingCount: evidence.mediaRetrieval.skippedExistingCount,
            failedCount: 1,
            recoveredLocalPathCount: evidence.mediaRetrieval.recoveredLocalPathCount - 1,
            recoveredMediaDirectoryPathPresent: evidence.mediaRetrieval.recoveredMediaDirectoryPathPresent,
            items: [failedItem]
        )

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: evidence.fixture.property.id, sessionID: evidence.fixture.session.id),
            restoreDiagnostics: evidence.restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: retrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("missing_media"))
        XCTAssertTrue(validation.blockers.contains("media_checksum_parity_failed"))
    }

    func testPackageParityValidationBlocksUnsupportedSchemaAndLocalNewerFreshness() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }
        var restore = evidence.restore
        restore.result = .localNewerConflict
        restore.snapshotSchemaVersion = 99
        restore.freshness = "local_newer"

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: evidence.fixture.property.id, sessionID: evidence.fixture.session.id),
            restoreDiagnostics: restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("unsupported_schema"))
        XCTAssertTrue(validation.blockers.contains("local_newer_freshness"))
    }

    func testPackageParityValidationDoesNotReportIntegrityFailureForFreshnessOnlyBlock() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }
        var restore = evidence.restore
        restore.result = .localNewerConflict
        restore.failureReason = "local session state is newer than snapshot"
        restore.freshness = "local_newer"

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: evidence.fixture.property.id, sessionID: evidence.fixture.session.id),
            restoreDiagnostics: restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("restore_diagnostics_not_restorable"))
        XCTAssertTrue(validation.blockers.contains("local_newer_freshness"))
        XCTAssertFalse(validation.blockers.contains("snapshot_package_integrity_not_verified"))
    }

    func testPackageParityValidationBlocksParentAndScopeMismatch() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }
        var restore = evidence.restore
        restore.result = .parentMismatch
        restore.parentRemoteVerified = false

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: UUID(), sessionID: evidence.fixture.session.id),
            restoreDiagnostics: restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("parent_mismatch"))
        XCTAssertTrue(validation.blockers.contains("scope_mismatch"))
    }

    func testPackageParityValidationBlocksUnsafeWriteAndMissingFallback() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: evidence.fixture.property.id, sessionID: evidence.fixture.session.id),
            restoreDiagnostics: evidence.restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison,
            remoteStateWriteAttempted: true,
            realLocalUserStateWriteAttempted: true,
            fallbackRetained: false
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("unsafe_write_attempt"))
        XCTAssertTrue(validation.blockers.contains("remote_state_write_attempted"))
        XCTAssertTrue(validation.blockers.contains("real_local_user_state_write_attempted"))
        XCTAssertTrue(validation.blockers.contains("fallback_missing"))
    }

    func testPackageParityValidationBlocksOriginalsOverwriteAttempt() async throws {
        let evidence = try await makePackageEvidence()
        defer { tearDownFixture(evidence.fixture) }

        let validation = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: AppState.ProductionCohortApprovalScope(orgID: evidence.fixture.orgID, propertyID: evidence.fixture.property.id, sessionID: evidence.fixture.session.id),
            restoreDiagnostics: evidence.restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(evidence.fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(evidence.fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(evidence.fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison,
            originalsOverwriteAttempted: true
        )

        XCTAssertEqual(validation.state, .blocked)
        XCTAssertTrue(validation.blockers.contains("originals_overwrite_attempt"))
    }

    func testRuntimeSelectedSessionQAAuthorizationRecordsExactScopeAndDoesNotEnableReads() throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }

        let status = fixture.appState.authorizeSelectedSessionForQAValidation(
            checkedAt: Date(timeIntervalSinceReferenceDate: 41_000)
        )

        XCTAssertEqual(status.state, .authorized)
        XCTAssertEqual(status.authorizedScope.orgID, fixture.orgID)
        XCTAssertEqual(status.authorizedScope.propertyID, fixture.property.id)
        XCTAssertEqual(status.authorizedScope.sessionID, fixture.session.id)
        XCTAssertTrue(status.scopeMatches)
        XCTAssertFalse(status.supabaseReadEnabled)
        XCTAssertFalse(status.productionWideCanonicalReadsEnabled)
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        let diagnostics = fixture.appState.localDiagnostics.sessionSnapshotUpload
        XCTAssertTrue(diagnostics.runtimeSelectedSessionQAAuthAuthorized)
        XCTAssertEqual(diagnostics.runtimeSelectedSessionQAAuthOrgID, fixture.orgID)
        XCTAssertEqual(diagnostics.runtimeSelectedSessionQAAuthPropertyID, fixture.property.id)
        XCTAssertEqual(diagnostics.runtimeSelectedSessionQAAuthSessionID, fixture.session.id)
    }

    func testSelectedSessionQAPresentationStateBlocksWhenNoSelectedPropertyOrSession() throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        fixture.appState.selectedPropertyID = nil
        fixture.appState.currentSession = nil

        let presentation = fixture.appState.localHealthSelectedSessionQAControlsPresentationState

        XCTAssertFalse(presentation.controlsMounted)
        XCTAssertEqual(presentation.blocker, "selected_session_required")
        XCTAssertNil(presentation.selectedPropertyID)
        XCTAssertNil(presentation.selectedSessionID)
        XCTAssertEqual(presentation.targetResolutionReason, "no property context")
    }

    func testSelectedSessionQAPresentationStateBlocksWhenSelectedPropertyHasNoSession() throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        fixture.appState.selectedPropertyID = fixture.property.id
        fixture.appState.currentSession = nil

        let presentation = fixture.appState.localHealthSelectedSessionQAControlsPresentationState

        XCTAssertFalse(presentation.controlsMounted)
        XCTAssertEqual(presentation.blocker, "selected_session_required")
        XCTAssertEqual(presentation.selectedPropertyID, fixture.property.id)
        XCTAssertNil(presentation.selectedSessionID)
        XCTAssertTrue(presentation.targetResolutionReason.contains("no local session"))
    }

    func testSelectedSessionQAPresentationStateAllowsControlsForValidSelectedSession() throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }

        let presentation = fixture.appState.localHealthSelectedSessionQAControlsPresentationState

        XCTAssertTrue(presentation.controlsMounted)
        XCTAssertNil(presentation.blocker)
        XCTAssertEqual(presentation.selectedPropertyID, fixture.property.id)
        XCTAssertEqual(presentation.selectedSessionID, fixture.session.id)
        XCTAssertEqual(presentation.targetResolutionReason, "active session selected")
    }

    func testRuntimeSelectedSessionQAAuthorizationRejectsMissingScopeExpiresAndInvalidatesOnSelectionChange() throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        fixture.appState.selectedPropertyID = nil

        let missing = fixture.appState.authorizeSelectedSessionForQAValidation(
            checkedAt: Date(timeIntervalSinceReferenceDate: 41_100)
        )
        XCTAssertEqual(missing.state, .blocked)
        XCTAssertEqual(missing.clearReason, "selected_session_snapshot_target_required")

        fixture.appState.selectedPropertyID = fixture.property.id
        let authorized = fixture.appState.authorizeSelectedSessionForQAValidation(
            checkedAt: Date(timeIntervalSinceReferenceDate: 41_200),
            expiresAt: Date(timeIntervalSinceReferenceDate: 41_230)
        )
        XCTAssertEqual(authorized.state, .authorized)

        let expired = fixture.appState.selectedSessionQAValidationAuthorizationStatus(
            checkedAt: Date(timeIntervalSinceReferenceDate: 41_260)
        )
        XCTAssertEqual(expired.state, .expired)
        XCTAssertEqual(expired.clearReason, "authorization_expired")

        _ = fixture.appState.authorizeSelectedSessionForQAValidation(
            checkedAt: Date(timeIntervalSinceReferenceDate: 41_300)
        )
        fixture.appState.selectedPropertyID = UUID()
        let invalidated = fixture.appState.selectedSessionQAValidationAuthorizationStatus(
            checkedAt: Date(timeIntervalSinceReferenceDate: 41_310)
        )
        XCTAssertEqual(invalidated.state, .notAuthorized)
        XCTAssertEqual(invalidated.clearReason, "selected_scope_changed")
    }

    func testRuntimeSelectedSessionQAAuthorizationInvalidatesOnActiveOrgChange() throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }

        _ = fixture.appState.authorizeSelectedSessionForQAValidation()
        fixture.appState._debugSetOrganizationContextForTests(
            memberships: [ActiveOrganizationMembership(id: UUID(), name: "Other Org", role: "owner")],
            activeOrganizationID: UUID(),
            ready: true
        )

        let status = fixture.appState.selectedSessionQAValidationAuthorizationStatus()
        XCTAssertEqual(status.state, .notAuthorized)
        XCTAssertEqual(status.clearReason, "active_org_changed")
    }

    func testSelectedSessionValidationPipelineBlocksWithoutValidAuthorization() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }

        let report = await fixture.appState.runSelectedSessionValidationPipeline()

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.finalBlocker, "valid_runtime_qa_authorization_required")
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastSelectedSessionValidationPipelineState, "blocked")
        XCTAssertNotEqual(
            fixture.appState.localDiagnostics.sessionSnapshotUpload.runtimeSelectedSessionQAAuthClearReason,
            "pipeline_completed"
        )
        assertPipelineDidNotEnableProductionBehavior(fixture)
    }

    func testSelectedSessionValidationPipelineStopsOnPackageValidationFailure() async throws {
        let evidence = try await makePackageEvidence()
        let fixture = evidence.fixture
        defer { tearDownFixture(fixture) }
        _ = fixture.appState.authorizeSelectedSessionForQAValidation()
        let badParity = AppState.makeProductionSingleSessionSnapshotPackageHydrationParityValidation(
            targetScope: scope(for: fixture),
            restoreDiagnostics: evidence.restore,
            hydration: evidence.hydration,
            hydratedMetadata: evidence.hydratedMetadata,
            snapshotShotIDs: Set(fixture.sourceMetadata.shots.map(\.shotID)),
            snapshotIssueIDs: Set(fixture.sourceMetadata.issues.map(\.issueID)),
            snapshotGuidedIDs: Set(fixture.sourceMetadata.guidedShots.map(\.id)),
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            candidateDiagnostics: evidence.candidate,
            overlayResult: evidence.overlay,
            overlayComparison: evidence.comparison,
            remoteStateWriteAttempted: true
        )
        let rollback = AppState.makeProductionSingleSessionFullyRestoredPackageRollbackValidation(
            targetScope: scope(for: fixture),
            restoreDiagnostics: evidence.restore,
            hydration: evidence.hydration,
            mediaRetrieval: evidence.mediaRetrieval,
            mediaRestoration: evidence.mediaRestoration,
            mediaRollback: evidence.mediaRollback,
            preHydrationFixtureFingerprint: "same",
            restoredFixtureFingerprint: "same",
            generatedRecoveredMediaArtifactsRemoved: true,
            generatedPackageCandidateArtifactsRemoved: true,
            originalsPreserved: true
        )
        let blockedPackage = AppState.LocalHealthSessionSnapshotPackageValidationReport(
            checkedAt: Date(timeIntervalSinceReferenceDate: 41_500),
            targetScope: scope(for: fixture),
            snapshotID: fixture.snapshotID,
            packageParity: badParity,
            fullyRestoredRollback: rollback,
            packageParityReportText: "blocked package parity",
            fullyRestoredRollbackReportText: "rollback passed",
            combinedReportText: "blocked package parity"
        )

        let report = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { blockedPackage },
            diagnosticsOperation: { _ in
                XCTFail("Pipeline must stop before diagnostics when package validation fails")
                return self.canonicalDiagnostics(fixture: fixture)
            }
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.finalBlocker, "remote_state_write_attempted")
        XCTAssertNotEqual(
            fixture.appState.localDiagnostics.sessionSnapshotUpload.runtimeSelectedSessionQAAuthClearReason,
            "pipeline_completed"
        )
        assertPipelineDidNotEnableProductionBehavior(fixture)
    }

    func testSelectedSessionValidationPipelineRunsObservationLifecycleAndOverlayToPass() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let package = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
        fixture.appState._debugSetOrganizationContextForTests(
            memberships: [ActiveOrganizationMembership(id: fixture.orgID, name: "27P Package Org", role: "owner")],
            activeOrganizationID: fixture.orgID,
            ready: true
        )
        fixture.appState.selectedPropertyID = fixture.property.id
        fixture.appState.currentSession = fixture.session
        let authorization = fixture.appState.authorizeSelectedSessionForQAValidation()
        XCTAssertEqual(authorization.state, .authorized)
        let initial = canonicalDiagnostics(
            fixture: fixture,
            result: .divergentConflict,
            localObservations: 1,
            remoteObservations: 0
        )
        let postObservation = canonicalDiagnostics(
            fixture: fixture,
            result: .divergentConflict,
            localObservations: 1,
            remoteObservations: 1,
            localStatus: "completed",
            remoteStatus: "in_progress"
        )
        let final = canonicalDiagnostics(fixture: fixture)

        let report = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { package },
            diagnosticsOperation: { _ in initial },
            observationReplayOperation: { _ in
                self.replayAction(fixture: fixture, diagnosticsAfterReplay: postObservation)
            },
            lifecycleReplayOperation: { _ in
                self.lifecycleAction(fixture: fixture, diagnosticsAfterReplay: final)
            }
        )
        XCTAssertEqual(report.state, .passed)
        XCTAssertTrue(report.observationReplayRequired)
        XCTAssertTrue(report.lifecycleReplayRequired)
        XCTAssertEqual(report.observationReplay?.replayResult?.upsertedCount, 2)
        XCTAssertEqual(report.lifecycleReplay?.replayResult?.upsertedCount, 1)
        XCTAssertTrue(report.candidateAllowed)
        XCTAssertNotNil(report.overlayBuild?.overlay)
        XCTAssertEqual(report.overlayComparison?.result, .candidateMatchesLocal)
        XCTAssertEqual(report.activeSource, "local")
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastCanonicalReadCandidateProductionWideEnabled)
        XCTAssertFalse(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastCanonicalCandidateActivationAllowed)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastCanonicalCandidateActivationActiveSource, "local")
        XCTAssertFalse(fixture.appState.localDiagnostics.sessionSnapshotUpload.runtimeSelectedSessionQAAuthAuthorized)
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.runtimeSelectedSessionQAAuthClearReason, "pipeline_completed")
        XCTAssertTrue(report.reportText.contains("- overlay_comparison_result: candidate_matches_local"))
        XCTAssertTrue(report.reportText.contains("- automatic_activation_performed: false"))
    }

    func testRuntimeAuthorizationAloneDoesNotEnableManualReplayActivationOrApprovalGates() async throws {
        let evidence = try await makePackageEvidence(includeCandidateAllowlist: false)
        let fixture = evidence.fixture
        defer { tearDownFixture(fixture) }
        let package = packageReport(from: evidence)
        let authorization = fixture.appState.authorizeSelectedSessionForQAValidation()
        XCTAssertEqual(authorization.state, .authorized)

        let manualObservation = await fixture.appState.replayFlaggedObservationShadowWritesForSelectedSession(
            productionValidationEvidence: package,
            replayOperation: { _, _ in
                XCTFail("Manual observation replay must not run under runtime-only QA authorization")
                return self.normalizedResult(kind: .observation, attemptedCount: 1, upsertedCount: 1)
            }
        )
        XCTAssertFalse(manualObservation.allowed)
        XCTAssertEqual(manualObservation.blockedReason, "exact_singleton_candidate_allowlist_required")

        let manualLifecycle = await fixture.appState.replaySelectedSessionLifecycleShadowWriteForSelectedSession(
            productionValidationEvidence: package,
            replayOperation: { _, _, _ in
                XCTFail("Manual lifecycle replay must not run under runtime-only QA authorization")
                return self.normalizedResult(kind: .session, attemptedCount: 1, upsertedCount: 1)
            }
        )
        XCTAssertFalse(manualLifecycle.allowed)
        XCTAssertEqual(manualLifecycle.blockedReason, "exact_singleton_candidate_allowlist_required")

        let activation = fixture.appState.activateCanonicalCandidateForSelectedSession()
        XCTAssertFalse(activation.allowed)
        XCTAssertEqual(activation.activeSource, .local)
        XCTAssertTrue(activation.blockedReason?.contains("org_not_allowlisted") ?? false)
        let gate = fixture.appState.productionSingleSessionActivationGateForSelectedSession()
        XCTAssertFalse(gate.gateAllowed)
        XCTAssertFalse(gate.operatorApprovalMatch)
    }

    func testPipelineOwnedReplayContextAllowsRuntimeAuthorizedReplayWithoutStaticAllowlists() async throws {
        let evidence = try await makePackageEvidence(includeCandidateAllowlist: false)
        let fixture = evidence.fixture
        defer { tearDownFixture(fixture) }
        let package = packageReport(from: evidence)
        let authorization = fixture.appState.authorizeSelectedSessionForQAValidation()
        let context = try runtimePipelineContext(fixture: fixture, authorization: authorization)

        let observation = await fixture.appState.replayFlaggedObservationShadowWritesForSelectedSession(
            productionValidationEvidence: package,
            pipelineAuthorizationContext: context,
            replayOperation: { _, _ in
                self.normalizedResult(kind: .observation, attemptedCount: 2, upsertedCount: 2)
            },
            diagnosticsAfterReplayOperation: {
                self.canonicalDiagnostics(fixture: fixture)
            }
        )
        XCTAssertTrue(observation.allowed)
        XCTAssertEqual(observation.replayResult?.upsertedCount, 2)

        let lifecycle = await fixture.appState.replaySelectedSessionLifecycleShadowWriteForSelectedSession(
            productionValidationEvidence: package,
            pipelineAuthorizationContext: context,
            replayOperation: { _, _, _ in
                self.normalizedResult(kind: .session, attemptedCount: 1, upsertedCount: 1)
            },
            diagnosticsAfterReplayOperation: { _, _, _ in
                self.canonicalDiagnostics(fixture: fixture)
            }
        )
        XCTAssertTrue(lifecycle.allowed)
        XCTAssertEqual(lifecycle.replayResult?.upsertedCount, 1)
    }

    func testStaticSchemeAllowlistsRemainBackwardCompatibleForManualReplayActions() async throws {
        let evidence = try await makePackageEvidence()
        let fixture = evidence.fixture
        defer { tearDownFixture(fixture) }
        let package = packageReport(from: evidence)

        let observation = await fixture.appState.replayFlaggedObservationShadowWritesForSelectedSession(
            productionValidationEvidence: package,
            replayOperation: { _, _ in
                self.normalizedResult(kind: .observation, attemptedCount: 1, upsertedCount: 1)
            },
            diagnosticsAfterReplayOperation: {
                self.canonicalDiagnostics(fixture: fixture)
            }
        )
        XCTAssertTrue(observation.allowed)

        let lifecycle = await fixture.appState.replaySelectedSessionLifecycleShadowWriteForSelectedSession(
            productionValidationEvidence: package,
            replayOperation: { _, _, _ in
                self.normalizedResult(kind: .session, attemptedCount: 1, upsertedCount: 1)
            },
            diagnosticsAfterReplayOperation: { _, _, _ in
                self.canonicalDiagnostics(fixture: fixture)
            }
        )
        XCTAssertTrue(lifecycle.allowed)
    }

    func testSelectedSessionValidationPipelinePreservesExpiryReasonWhenAuthExpiresDuringPipeline() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let package = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
        let now = Date()
        _ = fixture.appState.authorizeSelectedSessionForQAValidation(
            checkedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )

        let report = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: {
                _ = fixture.appState.selectedSessionQAValidationAuthorizationStatus(
                    checkedAt: now.addingTimeInterval(120)
                )
                return package
            }
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.finalBlocker, "authorization_invalidated")
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.runtimeSelectedSessionQAAuthClearReason, "authorization_expired")
    }

    func testSelectedSessionValidationPipelinePreservesActiveOrgReasonWhenInvalidatedDuringPipeline() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let package = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
        _ = fixture.appState.authorizeSelectedSessionForQAValidation()

        let report = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: {
                fixture.appState._debugSetOrganizationContextForTests(
                    memberships: [ActiveOrganizationMembership(id: UUID(), name: "Other Org", role: "owner")],
                    activeOrganizationID: UUID(),
                    ready: true
                )
                return package
            }
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.finalBlocker, "authorization_invalidated")
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.runtimeSelectedSessionQAAuthClearReason, "active_org_changed")
    }

    func testSelectedSessionValidationPipelinePreservesSelectionReasonWhenInvalidatedDuringPipeline() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let package = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
        _ = fixture.appState.authorizeSelectedSessionForQAValidation()

        let report = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: {
                fixture.appState.selectedPropertyID = UUID()
                return package
            }
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.finalBlocker, "authorization_invalidated")
        XCTAssertEqual(fixture.appState.localDiagnostics.sessionSnapshotUpload.runtimeSelectedSessionQAAuthClearReason, "selected_scope_changed")
    }

    func testQA9CarriedForwardSelectedSessionPipelineHappyPathKeepsLocalActive() async throws {
        let fixture = try makePackageFixture(includeCandidateAllowlist: false)
        defer { tearDownFixture(fixture) }
        let package = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
        _ = fixture.appState.authorizeSelectedSessionForQAValidation()
        let initial = canonicalDiagnostics(
            fixture: fixture,
            result: .divergentConflict,
            localObservations: 3,
            remoteObservations: 1
        )
        let postObservation = canonicalDiagnostics(
            fixture: fixture,
            result: .divergentConflict,
            localObservations: 3,
            remoteObservations: 3,
            localStatus: "completed",
            remoteStatus: "in_progress"
        )
        let final = canonicalDiagnostics(fixture: fixture, localObservations: 3, remoteObservations: 3)

        let report = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { package },
            diagnosticsOperation: { _ in initial },
            observationReplayOperation: { _ in
                self.replayAction(
                    fixture: fixture,
                    diagnosticsAfterReplay: postObservation,
                    attemptedCount: 3,
                    upsertedCount: 3
                )
            },
            lifecycleReplayOperation: { _ in
                self.lifecycleAction(fixture: fixture, diagnosticsAfterReplay: final)
            }
        )

        XCTAssertEqual(report.state, .passed)
        XCTAssertEqual(report.observationReplay?.replayResult?.attemptedCount, 3)
        XCTAssertEqual(report.observationReplay?.replayResult?.upsertedCount, 3)
        XCTAssertEqual(report.lifecycleReplay?.replayResult?.upsertedCount, 1)
        XCTAssertEqual(report.overlayComparison?.result, .candidateMatchesLocal)
        XCTAssertEqual(report.activeSource, "local")
        XCTAssertFalse(fixture.appState.backendFeatureFlags.supabaseReadEnabled)
        XCTAssertFalse(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastCanonicalReadCandidateProductionWideEnabled)
        XCTAssertFalse(fixture.appState.localDiagnostics.sessionSnapshotUpload.lastCanonicalCandidateActivationAllowed)
    }

    func testSelectedSessionValidationPipelineStopsOnObservationReplayFailure() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let package = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
        _ = fixture.appState.authorizeSelectedSessionForQAValidation()
        let initial = canonicalDiagnostics(
            fixture: fixture,
            result: .divergentConflict,
            localObservations: 2,
            remoteObservations: 1
        )

        let report = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { package },
            diagnosticsOperation: { _ in initial },
            observationReplayOperation: { _ in
                self.replayAction(fixture: fixture, diagnosticsAfterReplay: nil, failedCount: 1)
            }
        )

        XCTAssertEqual(report.state, .failed)
        XCTAssertEqual(report.finalBlocker, "observation_replay_failed")
        XCTAssertNotEqual(
            fixture.appState.localDiagnostics.sessionSnapshotUpload.runtimeSelectedSessionQAAuthClearReason,
            "pipeline_completed"
        )
        assertPipelineDidNotEnableProductionBehavior(fixture)
    }

    func testSelectedSessionValidationPipelineStopsOnLifecycleReplayFailure() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let package = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
        _ = fixture.appState.authorizeSelectedSessionForQAValidation()
        let initial = canonicalDiagnostics(
            fixture: fixture,
            result: .divergentConflict,
            localStatus: "completed",
            remoteStatus: "in_progress"
        )

        let report = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { package },
            diagnosticsOperation: { _ in initial },
            lifecycleReplayOperation: { _ in
                self.lifecycleAction(fixture: fixture, diagnosticsAfterReplay: nil, failedCount: 1)
            }
        )

        XCTAssertEqual(report.state, .failed)
        XCTAssertEqual(report.finalBlocker, "lifecycle_replay_failed")
        XCTAssertNotEqual(
            fixture.appState.localDiagnostics.sessionSnapshotUpload.runtimeSelectedSessionQAAuthClearReason,
            "pipeline_completed"
        )
        assertPipelineDidNotEnableProductionBehavior(fixture)
    }

    func testSelectedSessionValidationPipelineStopsOnRemoteNewerAndParentMismatch() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let package = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
        _ = fixture.appState.authorizeSelectedSessionForQAValidation()

        let remoteNewer = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { package },
            diagnosticsOperation: { _ in
                self.canonicalDiagnostics(fixture: fixture, result: .remoteNewerCandidate)
            }
        )
        XCTAssertEqual(remoteNewer.state, .blocked)
        XCTAssertEqual(remoteNewer.finalBlocker, "remote_newer_conflict")
        XCTAssertNil(remoteNewer.observationReplay)
        XCTAssertNil(remoteNewer.lifecycleReplay)
        assertPipelineDidNotEnableProductionBehavior(fixture)

        _ = fixture.appState.authorizeSelectedSessionForQAValidation()
        let parentMismatch = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { package },
            diagnosticsOperation: { _ in
                self.canonicalDiagnostics(fixture: fixture, parentOrgConsistent: false)
            }
        )
        XCTAssertEqual(parentMismatch.state, .blocked)
        XCTAssertEqual(parentMismatch.finalBlocker, "parent_mismatch")
    }

    func testSelectedSessionValidationPipelineStopsOnResidualCountAndStatusMismatch() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let package = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
        _ = fixture.appState.authorizeSelectedSessionForQAValidation()
        let initialCountGap = canonicalDiagnostics(
            fixture: fixture,
            result: .divergentConflict,
            localObservations: 2,
            remoteObservations: 1
        )
        let residualCountGap = canonicalDiagnostics(
            fixture: fixture,
            result: .divergentConflict,
            localObservations: 2,
            remoteObservations: 1
        )

        let countReport = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { package },
            diagnosticsOperation: { _ in initialCountGap },
            observationReplayOperation: { _ in
                self.replayAction(fixture: fixture, diagnosticsAfterReplay: residualCountGap)
            }
        )
        XCTAssertEqual(countReport.state, .blocked)
        XCTAssertEqual(countReport.finalBlocker, "count_mismatch_after_replay")

        _ = fixture.appState.authorizeSelectedSessionForQAValidation()
        let initialStatusGap = canonicalDiagnostics(
            fixture: fixture,
            result: .divergentConflict,
            localStatus: "completed",
            remoteStatus: "in_progress"
        )
        let residualStatusGap = canonicalDiagnostics(
            fixture: fixture,
            result: .divergentConflict,
            localStatus: "completed",
            remoteStatus: "in_progress"
        )
        let statusReport = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { package },
            diagnosticsOperation: { _ in initialStatusGap },
            lifecycleReplayOperation: { _ in
                self.lifecycleAction(fixture: fixture, diagnosticsAfterReplay: residualStatusGap)
            }
        )
        XCTAssertEqual(statusReport.state, .blocked)
        XCTAssertEqual(statusReport.finalBlocker, "status_mismatch_after_lifecycle_replay")
    }

    func testSelectedSessionValidationPipelineStopsOnFreshnessConflictAfterObservationBeforeLifecycle() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let package = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
        _ = fixture.appState.authorizeSelectedSessionForQAValidation()
        let initial = canonicalDiagnostics(
            fixture: fixture,
            result: .divergentConflict,
            localObservations: 2,
            remoteObservations: 1
        )
        let remoteNewerAfterObservation = canonicalDiagnostics(
            fixture: fixture,
            result: .remoteNewerCandidate,
            localObservations: 2,
            remoteObservations: 2,
            localStatus: "completed",
            remoteStatus: "in_progress"
        )

        let remoteNewerReport = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { package },
            diagnosticsOperation: { _ in initial },
            observationReplayOperation: { _ in
                self.replayAction(fixture: fixture, diagnosticsAfterReplay: remoteNewerAfterObservation)
            },
            lifecycleReplayOperation: { _ in
                XCTFail("Lifecycle replay must not run after remote-newer diagnostics")
                return self.lifecycleAction(fixture: fixture, diagnosticsAfterReplay: nil)
            }
        )
        XCTAssertEqual(remoteNewerReport.state, .blocked)
        XCTAssertEqual(remoteNewerReport.finalBlocker, "remote_newer_conflict")
        XCTAssertTrue(remoteNewerReport.observationReplayRequired)
        XCTAssertFalse(remoteNewerReport.lifecycleReplayRequired)
        XCTAssertNil(remoteNewerReport.lifecycleReplay)
        assertPipelineDidNotEnableProductionBehavior(fixture)

        _ = fixture.appState.authorizeSelectedSessionForQAValidation()
        let localNewerAfterObservation = canonicalDiagnostics(
            fixture: fixture,
            result: .localNewerConflict,
            localObservations: 2,
            remoteObservations: 2,
            localStatus: "completed",
            remoteStatus: "in_progress"
        )
        let localNewerReport = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { package },
            diagnosticsOperation: { _ in initial },
            observationReplayOperation: { _ in
                self.replayAction(fixture: fixture, diagnosticsAfterReplay: localNewerAfterObservation)
            },
            lifecycleReplayOperation: { _ in
                XCTFail("Lifecycle replay must not run after local-newer diagnostics")
                return self.lifecycleAction(fixture: fixture, diagnosticsAfterReplay: nil)
            }
        )
        XCTAssertEqual(localNewerReport.state, .blocked)
        XCTAssertEqual(localNewerReport.finalBlocker, "local_newer_conflict")
        XCTAssertTrue(localNewerReport.observationReplayRequired)
        XCTAssertFalse(localNewerReport.lifecycleReplayRequired)
        XCTAssertNil(localNewerReport.lifecycleReplay)
        assertPipelineDidNotEnableProductionBehavior(fixture)
    }

    func testSelectedSessionValidationPipelineBlocksFreshnessConflictAfterLifecycleBeforeOverlay() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let package = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
        _ = fixture.appState.authorizeSelectedSessionForQAValidation()
        let initialStatusGap = canonicalDiagnostics(
            fixture: fixture,
            result: .divergentConflict,
            localStatus: "completed",
            remoteStatus: "in_progress"
        )
        let remoteNewerAfterLifecycle = canonicalDiagnostics(
            fixture: fixture,
            result: .remoteNewerCandidate,
            localStatus: "completed",
            remoteStatus: "completed"
        )

        let report = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { package },
            diagnosticsOperation: { _ in initialStatusGap },
            lifecycleReplayOperation: { _ in
                self.lifecycleAction(fixture: fixture, diagnosticsAfterReplay: remoteNewerAfterLifecycle)
            },
            overlayEvidenceOperation: { diagnostics, _ in
                XCTFail("Overlay must not build after remote-newer lifecycle diagnostics")
                return self.overlayEvidence(fixture: fixture, diagnostics: diagnostics)
            }
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.finalBlocker, "remote_newer_conflict")
        XCTAssertTrue(report.lifecycleReplayRequired)
        XCTAssertNotNil(report.lifecycleReplay)
        XCTAssertNil(report.overlayBuild)
        assertPipelineDidNotEnableProductionBehavior(fixture)
    }

    func testSelectedSessionValidationPipelineStopsOnOverlayMismatch() async throws {
        let fixture = try makePackageFixture()
        defer { tearDownFixture(fixture) }
        let package = await fixture.appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
        _ = fixture.appState.authorizeSelectedSessionForQAValidation()
        let final = canonicalDiagnostics(fixture: fixture)

        let report = await fixture.appState.runSelectedSessionValidationPipeline(
            packageValidationOperation: { package },
            diagnosticsOperation: { _ in final },
            overlayEvidenceOperation: { diagnostics, _ in
                self.overlayEvidence(
                    fixture: fixture,
                    diagnostics: diagnostics,
                    comparisonResult: .candidateDivergent,
                    comparisonBlockedReason: "overlay_forced_mismatch"
                )
            }
        )

        XCTAssertEqual(report.state, .blocked)
        XCTAssertEqual(report.finalBlocker, "overlay_forced_mismatch")
        XCTAssertNotEqual(
            fixture.appState.localDiagnostics.sessionSnapshotUpload.runtimeSelectedSessionQAAuthClearReason,
            "pipeline_completed"
        )
        assertPipelineDidNotEnableProductionBehavior(fixture)
    }
}
