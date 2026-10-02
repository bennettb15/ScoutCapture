import XCTest
import UIKit
import ImageIO
@testable import ScoutCapture

@MainActor
final class GuidedSessionDurabilityRecoveryTests: XCTestCase {
    func testElevationChecklistCountsSavedTypesAndDistinctAnglesPerElevation() {
        func capture(_ building: String, _ elevation: String, _ detail: String, _ angle: Int) -> ElevationChecklistCapture {
            ElevationChecklistCapture(
                shotID: UUID(), building: building, elevation: elevation,
                detailType: detail, angleIndex: angle
            )
        }
        let captures = [
            capture("B1", "North", "Overview", 1),
            capture("B1", "North", "Overview", 1), // retake is a second photo, not a new angle
            capture("B1", "North", "Elevation", 1),
            capture("B1", "North", "Elevation", 2),
            capture("B1", "North", "Custom Flashing", 1),
            capture("B1", "North", "Custom Flashing", 2),
            capture("B1", "West", "Elevation", 1),
            capture("B2", "North", "Elevation", 3)
        ]
        let north = ElevationChecklist.rows(captures: captures, building: "B1", elevation: "North")
        XCTAssertEqual(north.map(\.title), ["Overview", "Elevation", "Custom Flashing"])
        XCTAssertEqual(north[0].photoCount, 2)
        XCTAssertEqual(north[0].angleCount, 1)
        XCTAssertEqual(north[1].countLabel, "2/3")
        XCTAssertEqual(north[2].photoCount, 2)
        XCTAssertEqual(north[2].angleCount, 2)
        XCTAssertEqual(north[2].countLabel, "2")
        XCTAssertNil(north[2].note)
        let west = ElevationChecklist.rows(captures: captures, building: "B1", elevation: "West Elevation")
        XCTAssertEqual(west.map(\.title), ["Overview", "Elevation"])
        XCTAssertEqual(west[1].countLabel, "1/3")
        XCTAssertEqual(ElevationChecklist.rows(captures: captures, building: "B2", elevation: "North")[1].countLabel, "1/3")
    }

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

    func testReclassifyingCapturedGuidedShotKeepsOnePhotoAndCompletedChecklistRow() async throws {
        let externalRoot = URL(fileURLWithPath: "/Volumes/Samsung 4TB/Codex/tmp/ScoutCapture", isDirectory: true)
        let root = externalRoot.appendingPathComponent("GuidedReclassification-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(testStorageRootURL: root)
        let org = try store.createOrganization(Organization(name: "Test Organization"))
        let property = try store.createProperty(Property(orgId: org.id, name: "Test Property", address: "100 Test Way"))
        let suiteName = "GuidedReclassification-\(UUID().uuidString)"
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
            ownerDeviceID: deviceID, createdAt: Date(), status: .draft, statusReason: "test"
        )
        let guidedID = UUID()
        try store.saveGuidedShots([
            GuidedShot(id: guidedID, title: "B1 East Downspout", building: "B1",
                       targetElevation: "East", detailType: "Downspout", angleIndex: 1)
        ], propertyID: property.id)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { renderer in
            UIColor.blue.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let save = await appState.saveFastRuntimePrototypeCapture(
            data: jpeg, context: context, capturedAt: Date(),
            metadataContext: AppState.FastRuntimeCaptureMetadataContext(
                locationMode: "Exterior", building: "B1", elevation: "East",
                detailType: "Downspout", angleIndex: 1, isGuided: true
            )
        )
        XCTAssertTrue(save.success, save.errorMessage ?? "")
        let shot = try XCTUnwrap(save.shot)
        let storageRoot = try XCTUnwrap(save.storageRoot)
        appState.projectFastRuntimeCaptureToLocalCameraState(context: context, shot: shot, guidedID: guidedID)
        XCTAssertTrue(appState.fastRuntimeReclassifyGuidedShot(
            propertyID: property.id, sessionID: context.sessionID, guidedShotID: guidedID,
            building: "B1", elevation: "East", detailType: "Elevation", angleIndex: 1,
            storageRoot: storageRoot
        ))
        let recordsData = try Data(contentsOf: storageRoot.appendingPathComponent("Metadata/fast-lane-shots.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([AppState.FastRuntimePrototypeShotRecord].self, from: recordsData)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, shot.id)
        XCTAssertEqual(records[0].metadataContext?.detailType, "Elevation")
        XCTAssertEqual(records[0].metadataContext?.shotKey,
                       ShotMetadata.makeShotKey(building: "B1", elevation: "East", detailType: "Elevation", angleIndex: 1))
        let rows = try store.fetchGuidedShots(propertyID: property.id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].shot?.id, shot.id)
        XCTAssertTrue(rows[0].isCompleted)
        XCTAssertEqual(rows[0].detailType, "Elevation")
        let session = try store.loadSessionMetadata(propertyID: property.id, sessionID: context.sessionID)
        XCTAssertEqual(session.shots.count, 1)
        XCTAssertEqual(session.shots[0].shotID, shot.id)
        XCTAssertEqual(session.shots[0].detailType, "Elevation")
        XCTAssertEqual(session.guidedShots.count, 1)
        XCTAssertEqual(session.guidedShots[0].shot?.id, shot.id)
    }

    func testReclassifyingCapturedFlaggedIssueKeepsOnePhotoAndItsIssueLink() async throws {
        let externalRoot = URL(fileURLWithPath: "/Volumes/Samsung 4TB/Codex/tmp/ScoutCapture", isDirectory: true)
        let root = externalRoot.appendingPathComponent("FlaggedReclassification-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(testStorageRootURL: root)
        let org = try store.createOrganization(Organization(name: "Test Organization"))
        let property = try store.createProperty(Property(orgId: org.id, name: "Test Property", address: "100 Test Way"))
        let suiteName = "FlaggedReclassification-\(UUID().uuidString)"
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
            ownerDeviceID: deviceID, createdAt: Date(), status: .draft, statusReason: "test"
        )
        let issueID = UUID()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { renderer in
            UIColor.blue.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let save = await appState.saveFastRuntimePrototypeCapture(
            data: jpeg, context: context, capturedAt: Date(),
            metadataContext: AppState.FastRuntimeCaptureMetadataContext(
                locationMode: "Exterior", building: "B1", elevation: "East",
                detailType: "Downspout", angleIndex: 1, isFlagged: true,
                issueID: issueID, issueStatus: "active"
            )
        )
        XCTAssertTrue(save.success, save.errorMessage ?? "")
        let shot = try XCTUnwrap(save.shot)
        let storageRoot = try XCTUnwrap(save.storageRoot)
        appState.projectFastRuntimeCaptureToLocalCameraState(context: context, shot: shot)
        XCTAssertTrue(appState.fastRuntimeReclassifyObservation(
            propertyID: property.id, sessionID: context.sessionID, observationID: issueID,
            building: "B1", elevation: "East", detailType: "Elevation", storageRoot: storageRoot
        ))

        let recordsData = try Data(contentsOf: storageRoot.appendingPathComponent("Metadata/fast-lane-shots.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([AppState.FastRuntimePrototypeShotRecord].self, from: recordsData)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, shot.id)
        XCTAssertEqual(records[0].metadataContext?.issueID, issueID)
        XCTAssertEqual(records[0].metadataContext?.detailType, "Elevation")
        XCTAssertEqual(records[0].metadataContext?.shotKey,
                       ShotMetadata.makeShotKey(building: "B1", elevation: "East", detailType: "Elevation", angleIndex: 1))
        let observations = try store.fetchObservations(propertyID: property.id)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].id, issueID)
        XCTAssertEqual(observations[0].linkedShotID, shot.id)
        XCTAssertEqual(observations[0].shots.map(\.id), [shot.id])
        XCTAssertEqual(observations[0].detailType, "Elevation")
        XCTAssertEqual(observations[0].guidedShots.first?.detailType, "Elevation")
        XCTAssertTrue(observations[0].historyEvents.contains { $0.kind == .reclassified && $0.shotID == shot.id })
        let session = try store.loadSessionMetadata(propertyID: property.id, sessionID: context.sessionID)
        XCTAssertEqual(session.shots.count, 1)
        XCTAssertEqual(session.shots[0].shotID, shot.id)
        XCTAssertEqual(session.shots[0].issueID, issueID)
        XCTAssertEqual(session.shots[0].detailType, "Elevation")
        let originals = try FileManager.default.contentsOfDirectory(
            at: store.originalsFolderURL(propertyID: property.id, sessionID: context.sessionID),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(originals.count, 1)
        // Drain the queued annotation and verify the projected original changed
        // classification without a second JPEG being written.
        try await FastRuntimeOriginalMetadata.prepareForUpload([])
        let finished = try Data(contentsOf: originals[0])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(finished as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let comment = try XCTUnwrap(exif[kCGImagePropertyExifUserComment] as? String)
        XCTAssertTrue(comment.contains("shotID=\(shot.id.uuidString)"))
        XCTAssertTrue(comment.contains("detailType=Elevation"))
        XCTAssertTrue(comment.contains("shotKey=\(try XCTUnwrap(records[0].metadataContext).shotKey)"))
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
