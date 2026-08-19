import XCTest
@testable import ScoutCapture

final class Phase2C08CutoverTests: XCTestCase {
    private func makeDefaultsSuite() -> UserDefaults {
        let suite = "Phase2C08CutoverTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-2C08-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testCutoverPhaseDerivesPhaseA() {
        let flags = BackendFeatureFlags(
            supabaseEnabled: false,
            shadowWriteEnabled: false,
            supabaseReadEnabled: false,
            supabasePropertyReadEnabled: true,
            mediaSupabaseUploadEnabled: false,
            syncDeltaEnabled: false,
            sessionCoordinationEnabled: false
        )

        XCTAssertEqual(flags.cutoverPhase, .phaseA)
    }

    func testCutoverPhaseDerivesPhaseB() {
        let flags = BackendFeatureFlags(
            supabaseEnabled: true,
            shadowWriteEnabled: true,
            supabaseReadEnabled: false,
            supabasePropertyReadEnabled: true,
            mediaSupabaseUploadEnabled: false,
            syncDeltaEnabled: false,
            sessionCoordinationEnabled: false
        )

        XCTAssertEqual(flags.cutoverPhase, .phaseB)
    }

    func testCutoverPhaseDerivesPhaseC() {
        let flags = BackendFeatureFlags(
            supabaseEnabled: true,
            shadowWriteEnabled: false,
            supabaseReadEnabled: true,
            supabasePropertyReadEnabled: true,
            mediaSupabaseUploadEnabled: true,
            syncDeltaEnabled: false,
            sessionCoordinationEnabled: false
        )

        XCTAssertEqual(flags.cutoverPhase, .phaseC)
    }

    func testRollbackInterpretationReloadsPhaseBToPhaseA() {
        let defaults = makeDefaultsSuite()

        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        let phaseBFlags = BackendFeatureFlags.load(userDefaults: defaults)
        XCTAssertEqual(phaseBFlags.cutoverPhase, .phaseB)

        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        let phaseAFlags = BackendFeatureFlags.load(userDefaults: defaults)
        XCTAssertEqual(phaseAFlags.cutoverPhase, .phaseA)
    }

    func testRollbackInterpretationReloadsPhaseCToPhaseB() {
        let defaults = makeDefaultsSuite()

        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(true, forKey: "supabase_read_enabled")
        let phaseCFlags = BackendFeatureFlags.load(userDefaults: defaults)
        XCTAssertEqual(phaseCFlags.cutoverPhase, .phaseC)

        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        let phaseBFlags = BackendFeatureFlags.load(userDefaults: defaults)
        XCTAssertEqual(phaseBFlags.cutoverPhase, .phaseB)
    }

    func testCutoverValidationWarningsHighlightSuspiciousCombos() {
        let flags = BackendFeatureFlags(
            supabaseEnabled: false,
            shadowWriteEnabled: true,
            supabaseReadEnabled: true,
            supabasePropertyReadEnabled: true,
            mediaSupabaseUploadEnabled: true,
            syncDeltaEnabled: false,
            sessionCoordinationEnabled: false
        )

        let warnings = AppState.cutoverConfigurationWarnings(for: flags)

        XCTAssertTrue(warnings.contains { $0.contains("shadow_write_enabled is ignored") })
        XCTAssertTrue(warnings.contains { $0.contains("supabase_read_enabled is ignored") })
        XCTAssertTrue(warnings.contains { $0.contains("supabase_property_read_enabled is ignored") })
        XCTAssertTrue(warnings.contains { $0.contains("media_supabase_upload_enabled is ignored") })
    }

    func testCutoverValidationWarningsHighlightBackendOnlyPhaseAAndDirectPhaseC() {
        let backendOnlyFlags = BackendFeatureFlags(
            supabaseEnabled: true,
            shadowWriteEnabled: false,
            supabaseReadEnabled: false,
            supabasePropertyReadEnabled: false,
            mediaSupabaseUploadEnabled: false,
            syncDeltaEnabled: false,
            sessionCoordinationEnabled: false
        )

        let backendOnlyWarnings = AppState.cutoverConfigurationWarnings(for: backendOnlyFlags)
        XCTAssertTrue(backendOnlyWarnings.contains { $0.contains("effective Phase A posture with backend bootstrap only") })

        let directPhaseCFlags = BackendFeatureFlags(
            supabaseEnabled: true,
            shadowWriteEnabled: false,
            supabaseReadEnabled: true,
            supabasePropertyReadEnabled: false,
            mediaSupabaseUploadEnabled: false,
            syncDeltaEnabled: false,
            sessionCoordinationEnabled: false
        )

        let directPhaseCWarnings = AppState.cutoverConfigurationWarnings(for: directPhaseCFlags)
        XCTAssertTrue(directPhaseCWarnings.contains { $0.contains("selects Phase C directly") })
    }

    func testPhaseBMediaDisabledKeepsExistingPendingShotState() {
        let flags = BackendFeatureFlags(
            supabaseEnabled: true,
            shadowWriteEnabled: true,
            supabaseReadEnabled: false,
            supabasePropertyReadEnabled: false,
            mediaSupabaseUploadEnabled: false,
            syncDeltaEnabled: false,
            sessionCoordinationEnabled: false
        )
        XCTAssertEqual(flags.cutoverPhase, .phaseB)

        let shot = ShotMetadata(
            shotID: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            building: "Building",
            elevation: "Front",
            detailType: "Overview",
            angleIndex: 1,
            shotKey: "building|front|overview|1",
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: "photo.heic",
            originalRelativePath: "Originals/photo.heic",
            originalByteSize: 128,
            uploadState: "pending",
            uploadAttempts: 0,
            lastUploadError: nil,
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

        XCTAssertNil(shot.storageBucket)
        XCTAssertNil(shot.storagePath)
        XCTAssertEqual(shot.uploadState, "pending")
        XCTAssertEqual(shot.uploadAttempts, 0)
        XCTAssertNil(shot.lastUploadError)
    }

    func testUnknownUploadStateNormalizesBackToPending() {
        let shot = ShotMetadata(
            shotID: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            building: "Building",
            elevation: "Front",
            detailType: "Overview",
            angleIndex: 1,
            shotKey: "building|front|overview|1",
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: "photo.heic",
            originalRelativePath: "Originals/photo.heic",
            originalByteSize: 128,
            uploadState: "pending_backfill",
            uploadAttempts: 0,
            lastUploadError: nil,
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

        XCTAssertEqual(shot.uploadState, "pending")
    }

    func testPhaseBPropertyShadowWriteFailureDoesNotBlockLocalWrite() async throws {
        let storageRoot = try makeTempStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let defaults = makeDefaultsSuite()
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "supabase_property_read_enabled")
        defaults.set(false, forKey: "media_supabase_upload_enabled")

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let organizationID = UUID()
        let shadowWriteAttempted = expectation(description: "shadow write attempted")

        let appState = AppState(
            localStore: localStore,
            userDefaults: defaults,
            propertyShadowWriteOverride: { _ in
                shadowWriteAttempted.fulfill()
                struct ForcedShadowWriteFailure: LocalizedError {
                    var errorDescription: String? { "forced shadow write failure" }
                }
                throw ForcedShadowWriteFailure()
            }
        )

        await MainActor.run {
            appState._debugSetOrganizationContextForTests(
                memberships: [
                    ActiveOrganizationMembership(
                        id: organizationID,
                        name: "Test Org",
                        role: "owner"
                    )
                ],
                activeOrganizationID: organizationID,
                ready: true
            )
        }

        let created = try appState.createProperty(
            organizationID: organizationID,
            clientName: "Client",
            propertyName: "2C-08 Property",
            address: "123 Main Street"
        )

        await fulfillment(of: [shadowWriteAttempted], timeout: 1.0)

        let persisted = try localStore.fetchProperties()
        XCTAssertTrue(persisted.contains(where: { $0.id == created.id }))
    }

    func testRemoteReadPropertyCreateWritesRemoteBeforeLocalAuthority() async throws {
        let storageRoot = try makeTempStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let defaults = makeDefaultsSuite()
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(true, forKey: "supabase_read_enabled")
        defaults.set(true, forKey: "supabase_property_read_enabled")

        actor Capture {
            var propertyIDs: [UUID] = []
            var statusBootstrapPropertyIDs: [UUID] = []
            var statusBootstrapReasons: [String] = []
            var statusBootstrapStatuses: [AppState.PropertyStatusValue] = []
            func append(_ id: UUID) { propertyIDs.append(id) }
            func appendStatusBootstrap(
                _ id: UUID,
                reason: String,
                status: AppState.PropertyStatusValue
            ) {
                statusBootstrapPropertyIDs.append(id)
                statusBootstrapReasons.append(reason)
                statusBootstrapStatuses.append(status)
            }
        }

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let organizationID = UUID()
        try localStore.createOrganization(Organization(id: organizationID, name: "Test Org"))
        let capture = Capture()
        let appState = AppState(
            localStore: localStore,
            userDefaults: defaults,
            propertyRemoteInsertOverride: { property in
                await capture.append(property.id)
            },
            propertyStatusBootstrapOverride: { property, reason in
                let record = Self.makeStatusRecord(
                    propertyID: property.id,
                    orgID: organizationID,
                    status: .idle,
                    heartbeatAt: nil,
                    statusReason: "\(reason):idle"
                )
                await capture.appendStatusBootstrap(property.id, reason: reason, status: record.status)
                return record
            }
        )

        await configureRemoteCreateEnvironment(appState, organizationID: organizationID)

        let created = try await appState.createPropertyRemoteAware(
            organizationID: organizationID,
            clientName: "Client",
            propertyName: "Remote Canonical Property",
            address: "123 Main Street",
            street: "123 Main Street",
            city: "Austin",
            state: "TX",
            zip: "78701"
        )

        let remoteWriteIDs = await capture.propertyIDs
        XCTAssertEqual(remoteWriteIDs, [created.id])
        let bootstrapIDs = await capture.statusBootstrapPropertyIDs
        let bootstrapReasons = await capture.statusBootstrapReasons
        XCTAssertEqual(bootstrapIDs, [created.id])
        XCTAssertEqual(bootstrapReasons, ["remote_property_create_bootstrap"])
        let entryDecision = appState.evaluatePropertyStatusEntryPreflight(propertyID: created.id)
        XCTAssertEqual(entryDecision?.decision, "allow")
        XCTAssertEqual(entryDecision?.reason, "status_idle")
        XCTAssertTrue(try localStore.fetchProperties().contains(where: { $0.id == created.id }))
    }

    func testRemoteReadPropertyCreatePreservesReturnedExistingPropertyStatus() async throws {
        let storageRoot = try makeTempStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let defaults = makeDefaultsSuite()
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(true, forKey: "supabase_property_read_enabled")

        actor Capture {
            var propertyIDs: [UUID] = []
            var statusBootstrapPropertyIDs: [UUID] = []
            var statusBootstrapReasons: [String] = []
            var statusBootstrapStatuses: [AppState.PropertyStatusValue] = []
            func append(_ id: UUID) { propertyIDs.append(id) }
            func appendStatusBootstrap(
                _ id: UUID,
                reason: String,
                status: AppState.PropertyStatusValue
            ) {
                statusBootstrapPropertyIDs.append(id)
                statusBootstrapReasons.append(reason)
                statusBootstrapStatuses.append(status)
            }
        }

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let organizationID = UUID()
        let pendingExportSessionID = UUID()
        try localStore.createOrganization(Organization(id: organizationID, name: "Test Org"))
        let capture = Capture()
        let appState = AppState(
            localStore: localStore,
            userDefaults: defaults,
            propertyRemoteInsertOverride: { property in
                await capture.append(property.id)
            },
            propertyStatusBootstrapOverride: { property, reason in
                let record = Self.makeStatusRecord(
                    propertyID: property.id,
                    orgID: organizationID,
                    status: .pendingExport,
                    pendingExportSessionID: pendingExportSessionID,
                    heartbeatAt: nil,
                    statusReason: "\(reason):pending_export",
                    revision: 7
                )
                await capture.appendStatusBootstrap(property.id, reason: reason, status: record.status)
                return record
            }
        )

        await configureRemoteCreateEnvironment(appState, organizationID: organizationID)

        let created = try await appState.createPropertyRemoteAware(
            organizationID: organizationID,
            clientName: "Client",
            propertyName: "Existing Status Property",
            address: "123 Main Street"
        )

        let remoteWriteIDs = await capture.propertyIDs
        XCTAssertEqual(remoteWriteIDs, [created.id])
        let statusRecord = appState.propertyStatusRecord(for: created.id)
        XCTAssertEqual(statusRecord?.status, .pendingExport)
        XCTAssertEqual(statusRecord?.pendingExportSessionID, pendingExportSessionID)
        XCTAssertEqual(statusRecord?.statusReason, "remote_property_create_bootstrap:pending_export")
        XCTAssertEqual(statusRecord?.revision, 7)
    }

    func testRemoteReadPropertyCreateFailureDoesNotPersistLocalOnlyProperty() async throws {
        let storageRoot = try makeTempStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let defaults = makeDefaultsSuite()
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(true, forKey: "supabase_read_enabled")
        defaults.set(true, forKey: "supabase_property_read_enabled")

        struct ForcedRemoteCreateFailure: LocalizedError {
            var errorDescription: String? { "forced remote create failure" }
        }

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let organizationID = UUID()
        let appState = AppState(
            localStore: localStore,
            userDefaults: defaults,
            propertyRemoteInsertOverride: { _ in
                throw ForcedRemoteCreateFailure()
            }
        )

        await configureRemoteCreateEnvironment(appState, organizationID: organizationID)

        do {
            _ = try await appState.createPropertyRemoteAware(
                organizationID: organizationID,
                clientName: "Client",
                propertyName: "Failed Remote Property",
                address: "123 Main Street",
                street: "123 Main Street",
                city: "Austin",
                state: "TX",
                zip: "78701"
            )
            XCTFail("Expected remote canonical property create to fail.")
        } catch let error as AppState.PropertyCreationError {
            guard case .remoteCreateFailed = error else {
                XCTFail("Expected remoteCreateFailed, got \(error).")
                return
            }
        }

        XCTAssertTrue(try localStore.fetchProperties().isEmpty)
    }

    func testSynchronousPropertyCreateIsRejectedInRemoteReadMode() async throws {
        let storageRoot = try makeTempStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let defaults = makeDefaultsSuite()
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        defaults.set(true, forKey: "supabase_read_enabled")
        defaults.set(true, forKey: "supabase_property_read_enabled")

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let organizationID = UUID()
        let appState = AppState(localStore: localStore, userDefaults: defaults)

        await configureRemoteCreateEnvironment(appState, organizationID: organizationID)

        XCTAssertThrowsError(
            try appState.createProperty(
                organizationID: organizationID,
                clientName: "Client",
                propertyName: "Local Only Property",
                address: "123 Main Street"
            )
        ) { error in
            guard case AppState.PropertyCreationError.remoteCreateUnavailable = error else {
                XCTFail("Expected remoteCreateUnavailable, got \(error).")
                return
            }
        }
        XCTAssertTrue(try localStore.fetchProperties().isEmpty)
    }

    func testPropertyReadEnabledPhaseBCreateWritesRemoteBeforeLocalAuthority() async throws {
        let storageRoot = try makeTempStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let defaults = makeDefaultsSuite()
        defaults.set(true, forKey: "supabase_enabled")
        defaults.set(true, forKey: "shadow_write_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(true, forKey: "supabase_property_read_enabled")

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let organizationID = UUID()
        try localStore.createOrganization(Organization(id: organizationID, name: "Test Org"))
        actor Capture {
            var propertyIDs: [UUID] = []
            var statusBootstrapPropertyIDs: [UUID] = []
            var statusBootstrapReasons: [String] = []
            var statusBootstrapStatuses: [AppState.PropertyStatusValue] = []
            func append(_ id: UUID) { propertyIDs.append(id) }
            func appendStatusBootstrap(
                _ id: UUID,
                reason: String,
                status: AppState.PropertyStatusValue
            ) {
                statusBootstrapPropertyIDs.append(id)
                statusBootstrapReasons.append(reason)
                statusBootstrapStatuses.append(status)
            }
        }
        let capture = Capture()
        let appState = AppState(
            localStore: localStore,
            userDefaults: defaults,
            propertyRemoteInsertOverride: { property in
                await capture.append(property.id)
            },
            propertyStatusBootstrapOverride: { property, reason in
                let record = Self.makeStatusRecord(
                    propertyID: property.id,
                    orgID: organizationID,
                    status: .idle,
                    heartbeatAt: nil,
                    statusReason: "\(reason):idle"
                )
                await capture.appendStatusBootstrap(property.id, reason: reason, status: record.status)
                return record
            }
        )

        await configureRemoteCreateEnvironment(appState, organizationID: organizationID)

        let created = try await appState.createPropertyRemoteAware(
            organizationID: organizationID,
            clientName: "Client",
            propertyName: "Property Read Enabled Phase B Property",
            address: "123 Main Street"
        )

        let remoteWriteIDs = await capture.propertyIDs
        XCTAssertEqual(remoteWriteIDs, [created.id])
        let bootstrapIDs = await capture.statusBootstrapPropertyIDs
        let bootstrapReasons = await capture.statusBootstrapReasons
        let bootstrapStatuses = await capture.statusBootstrapStatuses
        XCTAssertEqual(bootstrapIDs, [created.id])
        XCTAssertEqual(bootstrapReasons, ["remote_property_create_bootstrap"])
        XCTAssertEqual(bootstrapStatuses, [.idle])
        let entryDecision = appState.evaluatePropertyStatusEntryPreflight(propertyID: created.id)
        XCTAssertEqual(entryDecision?.decision, "allow")
        XCTAssertEqual(entryDecision?.reason, "status_idle")
        XCTAssertTrue(try localStore.fetchProperties().contains(where: { $0.id == created.id }))
    }

    private static func makeStatusRecord(
        propertyID: UUID,
        orgID: UUID,
        status: AppState.PropertyStatusValue,
        activeSessionID: UUID? = nil,
        draftSessionID: UUID? = nil,
        pendingExportSessionID: UUID? = nil,
        lastExportedSessionID: UUID? = nil,
        ownerUserID: UUID? = nil,
        ownerDeviceID: String? = nil,
        heartbeatAt: Date? = Date(),
        statusReason: String? = nil,
        revision: Int64 = 1
    ) -> AppState.PropertyStatusRecord {
        AppState.PropertyStatusRecord(
            propertyID: propertyID,
            orgID: orgID,
            status: status,
            activeSessionID: activeSessionID,
            draftSessionID: draftSessionID,
            pendingExportSessionID: pendingExportSessionID,
            lastExportedSessionID: lastExportedSessionID,
            ownerUserID: ownerUserID,
            ownerDeviceID: ownerDeviceID,
            heartbeatAt: heartbeatAt,
            updatedAt: Date(),
            updatedBy: ownerUserID,
            statusReason: statusReason ?? "test:\(status.rawValue)",
            revision: revision
        )
    }

    @MainActor
    private func configureRemoteCreateEnvironment(
        _ appState: AppState,
        organizationID: UUID
    ) {
        appState.stopAuthenticationObservation()
        appState._debugSetOrganizationContextForTests(
            memberships: [
                ActiveOrganizationMembership(
                    id: organizationID,
                    name: "Test Org",
                    role: "owner"
                )
            ],
            activeOrganizationID: organizationID,
            ready: true
        )
        appState._debugSetOfflineReplayEnvironmentForTests(
            activeOrganizationID: organizationID,
            ready: true,
            clientConfigured: true,
            authenticated: true,
            authenticationReady: true
        )
    }
}
