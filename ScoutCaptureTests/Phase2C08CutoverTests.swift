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
            syncDeltaEnabled: false
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
            syncDeltaEnabled: false
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
            syncDeltaEnabled: false
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
            syncDeltaEnabled: false
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
            syncDeltaEnabled: false
        )

        let backendOnlyWarnings = AppState.cutoverConfigurationWarnings(for: backendOnlyFlags)
        XCTAssertTrue(backendOnlyWarnings.contains { $0.contains("effective Phase A posture with backend bootstrap only") })

        let directPhaseCFlags = BackendFeatureFlags(
            supabaseEnabled: true,
            shadowWriteEnabled: false,
            supabaseReadEnabled: true,
            supabasePropertyReadEnabled: false,
            mediaSupabaseUploadEnabled: false,
            syncDeltaEnabled: false
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
            syncDeltaEnabled: false
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
}
