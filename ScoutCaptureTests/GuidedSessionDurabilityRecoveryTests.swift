import XCTest
import UIKit
@testable import ScoutCapture

@MainActor
final class GuidedSessionDurabilityRecoveryTests: XCTestCase {
    func testFastLaneCaptureCheckpointsDraftAndSessionJSONAtShutter() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastLaneCheckpoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(testStorageRootURL: root)
        let org = try store.createOrganization(Organization(name: "Test Organization"))
        let property = try store.createProperty(Property(orgId: org.id, name: "Test Property", address: "100 Test Way"))
        let suiteName = "FastLaneCheckpoint-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        let appState = AppState(localStore: store, userDefaults: defaults)
        appState._debugRefreshPropertiesLocallyForTests()
        let deviceID = try XCTUnwrap(defaults.string(forKey: "scoutcapture.deviceIdentifier.v1"))
        let context = ActiveCaptureContext(
            sessionID: UUID(), propertyID: property.id, orgID: org.id,
            sessionType: .fullDocumentation, ownerUserID: nil, ownerEmail: nil,
            ownerDeviceID: deviceID, createdAt: Date().addingTimeInterval(-3600), status: .draft, statusReason: "test"
        )
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { renderer in
            UIColor.blue.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let captureMetadata = AppState.FastRuntimeCaptureMetadataContext(
            locationMode: "Exterior", building: "B1", elevation: "North",
            detailType: "Overview", angleIndex: 1, isGuided: true
        )
        let result = await appState.saveFastRuntimePrototypeCapture(
            data: jpeg, context: context, capturedAt: Date(), metadataContext: captureMetadata
        )
        XCTAssertTrue(result.success, result.errorMessage ?? "")
        let shot = try XCTUnwrap(result.shot)
        XCTAssertEqual(appState.fastRuntimeDraftsByPropertyID[property.id]?.photoCount, 1)
        let draftRecords = try Data(contentsOf: XCTUnwrap(result.storageRoot)
            .appendingPathComponent("Metadata/fast-lane-shots.json"))
        XCTAssertFalse(draftRecords.isEmpty)
        appState.projectFastRuntimeCaptureToLocalCameraState(context: context, shot: shot)
        let indexed = try store.fetchSessions(propertyID: property.id)
        XCTAssertEqual(indexed.map(\.id), [context.sessionID])
        let sessionMetadata = try store.loadSessionMetadata(propertyID: property.id, sessionID: context.sessionID)
        XCTAssertEqual(sessionMetadata.shots.map(\.shotID), [shot.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionFolderURL(
            propertyID: property.id, sessionID: context.sessionID
        ).appendingPathComponent("session.json").path))
        XCTAssertTrue(appState.propertyCardBadgeModel(for: property.id).showDraft)
        XCTAssertTrue(appState.prepareFastRuntimeCompletion(
            context: context, storageRoot: result.storageRoot, shots: []
        ))
        XCTAssertFalse(appState.propertyCardBadgeModel(for: property.id).showDraft)
        XCTAssertEqual(appState.propertyRowDraftCount, 0)

        // An older indexed draft must not displace a newer interrupted capture.
        let newerSessionID = UUID()
        let newerShotID = UUID()
        try store.ensureSessionFileStorage(propertyID: property.id, sessionID: newerSessionID)
        let newerOriginal = store.originalsDirectoryURL(propertyID: property.id, sessionID: newerSessionID)
            .appendingPathComponent("\(newerShotID.uuidString).jpg")
        try jpeg.write(to: newerOriginal, options: .atomic)
        let newerGuided = GuidedShot(
            title: "B1 North Window", building: "B1", targetElevation: "North",
            detailType: "Window", angleIndex: 1,
            shot: Shot(id: newerShotID, capturedAt: Date().addingTimeInterval(60), imageLocalIdentifier: newerOriginal.path),
            isCompleted: true
        )
        try store.saveGuidedShots([newerGuided], propertyID: property.id)
        let selectedDraft = try XCTUnwrap(appState.fastRuntimeDraftResumeState(for: property.id))
        XCTAssertEqual(selectedDraft.context?.sessionID, newerSessionID)
        XCTAssertEqual(selectedDraft.summary?.photoCount, 1)
    }

    func testMissingSessionJSONRecoversOnlyOriginalsInCurrentContainerAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuidedSessionDurability-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(testStorageRootURL: root)
        let org = try store.createOrganization(Organization(name: "Test Organization"))
        let property = try store.createProperty(Property(orgId: org.id, name: "Test Property", address: "100 Test Way"))
        let suiteName = "GuidedSessionDurability-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "supabase_enabled")
        defaults.set(false, forKey: "supabase_read_enabled")
        defaults.set(false, forKey: "shadow_write_enabled")
        // Populate AppState's session cache before the interrupted capture is
        // left on disk. Property entry must refresh this stale cache.
        let appState = AppState(localStore: store, userDefaults: defaults)
        appState._debugRefreshPropertiesLocallyForTests()
        appState.selectProperty(id: property.id)
        let liveSessionID = UUID()
        let staleSessionID = UUID()
        let captureDate = Date().addingTimeInterval(-60)
        try store.ensureSessionFileStorage(propertyID: property.id, sessionID: liveSessionID)

        let guidedShots: [GuidedShot] = try (0..<8).map { index in
            let shotID = UUID()
            let sessionID = index < 3 ? liveSessionID : staleSessionID
            let originalURL = store.originalsDirectoryURL(propertyID: property.id, sessionID: sessionID)
                .appendingPathComponent("\(shotID.uuidString).jpg")
            if index < 3 {
                try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: originalURL, options: .atomic)
            }
            return GuidedShot(
                title: "Checkpoint \(index)",
                building: "B1",
                targetElevation: "North",
                detailType: "Detail \(index)",
                angleIndex: 1,
                shot: Shot(id: shotID, capturedAt: captureDate.addingTimeInterval(Double(index)), imageLocalIdentifier: originalURL.path),
                isCompleted: true
            )
        }
        try store.saveGuidedShots(guidedShots, propertyID: property.id)

        XCTAssertEqual(appState.preferredPropertyEntrySessionID(for: property.id), liveSessionID)
        let recovered = try store.fetchSessionsForCacheBuild(propertyID: property.id)
        XCTAssertEqual(recovered.map(\.id), [liveSessionID])
        let metadata = try store.loadSessionMetadata(propertyID: property.id, sessionID: liveSessionID)
        XCTAssertEqual(Set(metadata.shots.map(\.shotID)), Set(guidedShots.prefix(3).compactMap { $0.shot?.id }))
        XCTAssertEqual(metadata.shots.count, 3)
        XCTAssertEqual(metadata.guidedShots.filter(\.isCompleted).count, 3)
        XCTAssertEqual(metadata.guidedShots.filter { !$0.isCompleted }.count, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionFolderURL(propertyID: property.id, sessionID: liveSessionID).appendingPathComponent("session.json").path))

        let repeated = try store.fetchSessions(propertyID: property.id)
        XCTAssertEqual(repeated.count, 1)
        XCTAssertEqual(try store.loadSessionMetadata(propertyID: property.id, sessionID: liveSessionID).shots.count, 3)

        // Existing photos can survive with their guided links and checklist
        // snapshot missing. Reopening the property must repair those links.
        var unlinked = try store.loadSessionMetadata(propertyID: property.id, sessionID: liveSessionID)
        for index in unlinked.shots.indices { unlinked.shots[index].isGuided = false }
        unlinked.guidedShots = []
        unlinked.orgID = UUID() // The demo property moved to a different organization.
        try store.saveSessionMetadataAtomically(
            propertyID: property.id, sessionID: liveSessionID, metadata: unlinked
        )
        _ = try store.fetchSessions(propertyID: property.id)
        let relinked = try store.loadSessionMetadata(propertyID: property.id, sessionID: liveSessionID)
        XCTAssertEqual(relinked.shots.filter(\.isGuided).count, 3)
        XCTAssertEqual(relinked.guidedShots.filter(\.isCompleted).count, 3)
        XCTAssertEqual(relinked.guidedShots.filter { !$0.isCompleted }.count, 5)

        let fastDraft = try XCTUnwrap(appState.fastRuntimeDraftResumeState(for: property.id))
        XCTAssertEqual(fastDraft.context?.sessionID, liveSessionID)
        XCTAssertEqual(fastDraft.summary?.photoCount, 3)
        let fastRecordsURL = try XCTUnwrap(fastDraft.storageRoot)
            .appendingPathComponent("Metadata/fast-lane-shots.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fastRecords = try decoder.decode(
            [AppState.FastRuntimePrototypeShotRecord].self,
            from: Data(contentsOf: fastRecordsURL)
        )
        XCTAssertEqual(Set(fastRecords.map(\.id)), Set(guidedShots.prefix(3).compactMap { $0.shot?.id }))
        XCTAssertTrue(fastRecords.allSatisfy { FileManager.default.fileExists(atPath: $0.localFilePath) })
        XCTAssertEqual(appState.fastRuntimeDraftResumeState(for: property.id)?.summary?.photoCount, 3)

        XCTAssertEqual(appState.startSession(skipPropertyStatusPreflight: true)?.id, liveSessionID)
    }
}
