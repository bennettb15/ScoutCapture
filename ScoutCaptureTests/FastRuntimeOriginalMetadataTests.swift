import CoreLocation
import CryptoKit
import ImageIO
import UIKit
import XCTest
@testable import ScoutCapture

final class FastRuntimeOriginalMetadataTests: XCTestCase {
    private func makeCameraJPEG() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.02],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 1.0,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.0,
                kCGImagePropertyGPSLongitudeRef: "E"
            ] as [CFString: Any]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func makeShot(at url: URL) -> AppState.FastRuntimePrototypeShotRecord {
        let shotID = UUID()
        return AppState.FastRuntimePrototypeShotRecord(
            id: shotID,
            sessionID: UUID(),
            propertyID: UUID(),
            orgID: UUID(),
            sessionType: .fullDocumentation,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            localFilePath: url.path,
            originalRelativePath: "Originals/\(shotID.uuidString).jpg",
            captureKind: "captured",
            firstCaptureKind: "captured",
            captureLocationMode: "Exterior",
            metadataContext: AppState.FastRuntimeCaptureMetadataContext(
                locationMode: "Exterior",
                building: "B1",
                elevation: "North",
                detailType: "Overview",
                shotKey: "b1|north|overview|1",
                propertyName: "Test Property",
                propertyAddress: "10 Main Street",
                latitude: 40.123,
                longitude: -73.456,
                accuracyMeters: 8.5,
                captureMode: "hd",
                lens: "wide"
            )
        )
    }

    private func withRawOriginal(_ body: (URL, AppState.FastRuntimePrototypeShotRecord) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FastMetadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("original.jpg")
        try makeCameraJPEG().write(to: url)
        try await body(url, makeShot(at: url))
    }

    private func number(_ value: Any?) throws -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String, let number = Double(text) { return number }
        XCTFail("Missing numeric metadata value")
        return .nan
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func testAllowedLocationEmbedsGPSAccuracyAndScoutFieldsWithoutDroppingCameraEXIF() async throws {
        try await withRawOriginal { url, shot in
            let original = try Data(contentsOf: url)
            try FastRuntimeOriginalMetadata.annotateIfNeeded(shot, authorizationStatus: .authorizedWhenInUse)
            let finished = try Data(contentsOf: url)
            let metadata = try properties(finished)
            let gps = try XCTUnwrap(metadata[kCGImagePropertyGPSDictionary] as? [CFString: Any])
            XCTAssertEqual(try number(gps[kCGImagePropertyGPSLatitude]), 40.123, accuracy: 0.001)
            XCTAssertEqual(try number(gps[kCGImagePropertyGPSLongitude]), 73.456, accuracy: 0.001)
            XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "W")
            XCTAssertEqual(try number(gps[kCGImagePropertyGPSHPositioningError]), 8.5, accuracy: 1.0)
            XCTAssertTrue(FastRuntimeOriginalMetadata.containsScoutShotID(finished, shotID: shot.id))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(finished as CFData, nil))
            let xmp = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
            let shotTag = try XCTUnwrap(CGImageMetadataCopyTagWithPath(xmp, nil, "scout:shotID" as CFString))
            XCTAssertEqual(CGImageMetadataTagCopyValue(shotTag) as? String, shot.id.uuidString)
            let accuracyTag = try XCTUnwrap(CGImageMetadataCopyStringValueWithPath(
                xmp, nil, "scout:gpsAccuracyMeters" as CFString
            ))
            XCTAssertEqual(accuracyTag as String, "8.500")
            let storedGPS = try XCTUnwrap(FastRuntimeOriginalMetadata.embeddedGPS(at: url))
            XCTAssertEqual(storedGPS.latitude, 40.123, accuracy: 0.001)
            XCTAssertEqual(storedGPS.longitude, -73.456, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(storedGPS.accuracyMeters), 8.5, accuracy: 0.001)
            let exif = try XCTUnwrap(metadata[kCGImagePropertyExifDictionary] as? [CFString: Any])
            XCTAssertEqual(try XCTUnwrap(exif[kCGImagePropertyExifExposureTime] as? NSNumber).doubleValue, 0.02, accuracy: 0.001)
            let tiff = try XCTUnwrap(metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
            XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "Apple")
            XCTAssertEqual((metadata[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)
            XCTAssertNotEqual(original, finished)
        }
    }

    func testReclassificationRefreshesEmbeddedPhotoMetadataWithoutNewOriginal() async throws {
        try await withRawOriginal { url, shot in
            try FastRuntimeOriginalMetadata.annotateIfNeeded(shot, authorizationStatus: .denied)
            var revised = shot
            revised.metadataContext = try XCTUnwrap(shot.metadataContext).reclassified(
                building: "B1", elevation: "East", detailType: "Downspout", angleIndex: 2
            )
            try FastRuntimeOriginalMetadata.annotateIfNeeded(revised, authorizationStatus: .denied)
            let finished = try Data(contentsOf: url)
            let exif = try XCTUnwrap((try properties(finished))[kCGImagePropertyExifDictionary] as? [CFString: Any])
            let comment = try XCTUnwrap(exif[kCGImagePropertyExifUserComment] as? String)
            XCTAssertTrue(comment.contains("shotID=\(shot.id.uuidString)"))
            XCTAssertTrue(comment.contains("shotKey=\(try XCTUnwrap(revised.metadataContext).shotKey)"))
            XCTAssertTrue(comment.contains("elevation=East"))
            XCTAssertTrue(comment.contains("detailType=Downspout"))
            XCTAssertFalse(comment.contains("shotKey=b1|north|overview|1"))
        }
    }

    func testRevokedLocationRemovesSourceGPSAndStillEmbedsScoutFields() async throws {
        try await withRawOriginal { url, shot in
            try FastRuntimeOriginalMetadata.annotateIfNeeded(shot, authorizationStatus: .denied)
            let finished = try Data(contentsOf: url)
            XCTAssertFalse(FastRuntimeOriginalMetadata.hasGPS(finished))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(finished as CFData, nil))
            let xmp = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
            XCTAssertNil(CGImageMetadataCopyStringValueWithPath(xmp, nil, "exif:GPSLatitude" as CFString))
            XCTAssertTrue(FastRuntimeOriginalMetadata.containsScoutShotID(finished, shotID: shot.id))
            XCTAssertEqual(((try properties(finished))[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)
        }
    }

    @MainActor
    func testWriteFailureBlocksAppUploadAndRetryFingerprintsFinishedJPEG() async throws {
        try await withRawOriginal { url, shot in
            let root = url.deletingLastPathComponent()
            let metadataFolder = root.appendingPathComponent("Metadata", isDirectory: true)
            try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([shot]).write(to: metadataFolder.appendingPathComponent("fast-lane-shots.json"))
            let context = ActiveCaptureContext(
                sessionID: shot.sessionID,
                propertyID: shot.propertyID,
                orgID: shot.orgID,
                sessionType: shot.sessionType,
                ownerUserID: UUID(),
                ownerEmail: "test@example.com",
                ownerDeviceID: "metadata-gate-test",
                createdAt: shot.capturedAt,
                status: .draft,
                statusReason: nil
            )
            let appState = AppState(disableCloudBackupForTests: true)
            let raw = try Data(contentsOf: url)
            let rawChecksum = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()

            // The JPEG remains readable, but ImageIO cannot write its sibling temporary file.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            let failed = await appState.runFastRuntimeCompleteUpload(
                context: context, storageRoot: root, capturedPhotoCount: 1
            )
            XCTAssertFalse(failed.success)
            XCTAssertEqual(failed.packageSummary, "skipped_original_metadata_failure")
            XCTAssertEqual(failed.uploadedFilesCount, 0)
            XCTAssertTrue(failed.createdRowsSummary.isEmpty)
            XCTAssertTrue(failed.shots.isEmpty)
            XCTAssertTrue(failed.diagnostics.contains("stage=original_metadata_preflight"))
            XCTAssertEqual(try Data(contentsOf: url), raw)

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let retried = await appState.runFastRuntimeCompleteUpload(
                context: context, storageRoot: root, capturedPhotoCount: 1
            )
            // This fixture has no authorized organization. Reaching the later organization
            // gate proves metadata preflight succeeded on retry without a network upload.
            XCTAssertEqual(retried.packageSummary, "skipped_missing_or_inactive_org")
            XCTAssertTrue(retried.diagnostics.contains { $0 == "stage=org_resolution" })
            let finished = try Data(contentsOf: url)
            XCTAssertTrue(FastRuntimeOriginalMetadata.containsScoutShotID(finished, shotID: shot.id))
            XCTAssertNotEqual(finished, raw)
            let fingerprint = try FastRuntimeOriginalMetadata.uploadFingerprint(at: url)
            XCTAssertEqual(fingerprint.byteSize, finished.count)
            XCTAssertEqual(
                fingerprint.checksumSHA256,
                SHA256.hash(data: finished).map { String(format: "%02x", $0) }.joined()
            )
            XCTAssertNotEqual(fingerprint.checksumSHA256, rawChecksum)
        }
    }

    @MainActor
    func testUploadPreflightUsesPhotoMovedWithDraftInsteadOfStaleTemporaryPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FastMetadata-Moved-\(UUID().uuidString)")
        let originals = root.appendingPathComponent("Originals", isDirectory: true)
        let metadata = root.appendingPathComponent("Metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staleURL = root.appendingPathComponent("old-temporary-photo.jpg")
        let shot = makeShot(at: staleURL)
        let savedURL = root.appendingPathComponent(shot.originalRelativePath)
        try makeCameraJPEG().write(to: savedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([shot]).write(
            to: metadata.appendingPathComponent("fast-lane-shots.json")
        )
        let context = ActiveCaptureContext(
            sessionID: shot.sessionID,
            propertyID: shot.propertyID,
            orgID: shot.orgID,
            sessionType: shot.sessionType,
            ownerUserID: UUID(),
            ownerEmail: "test@example.com",
            ownerDeviceID: "relocated-draft-test",
            createdAt: shot.capturedAt,
            status: .draft,
            statusReason: nil
        )
        let appState = AppState(disableCloudBackupForTests: true)
        let result = await appState.runFastRuntimeCompleteUpload(
            context: context, storageRoot: root, capturedPhotoCount: 1
        )
        XCTAssertEqual(result.packageSummary, "skipped_missing_or_inactive_org")
        XCTAssertTrue(result.diagnostics.contains("stage=org_resolution"))
        XCTAssertTrue(FastRuntimeOriginalMetadata.containsScoutShotID(
            try Data(contentsOf: savedURL), shotID: shot.id
        ))
    }

    func testUploadPreparationWaitsForMetadataAndFailureKeepsRawOriginal() async throws {
        try await withRawOriginal { url, shot in
            let durable = url.deletingLastPathComponent().appendingPathComponent("gallery-copy.jpg")
            try Data(contentsOf: url).write(to: durable)
            XCTAssertFalse(FastRuntimeOriginalMetadata.containsScoutShotID(try Data(contentsOf: url), shotID: shot.id))
            try await FastRuntimeOriginalMetadata.prepareForUpload(
                [shot], durableURLsByShotID: [shot.id: durable], authorizationStatus: .authorizedWhenInUse
            )
            let finished = try Data(contentsOf: url)
            XCTAssertTrue(FastRuntimeOriginalMetadata.containsScoutShotID(finished, shotID: shot.id))
            XCTAssertEqual(try Data(contentsOf: durable), finished)
        }
        try await withRawOriginal { url, shot in
            let invalid = Data("not a JPEG".utf8)
            try invalid.write(to: url)
            do {
                try await FastRuntimeOriginalMetadata.prepareForUpload([shot], authorizationStatus: .denied)
                XCTFail("Upload preflight must fail before any upload can begin")
            } catch {
                XCTAssertEqual(try Data(contentsOf: url), invalid)
            }
        }
    }
}
