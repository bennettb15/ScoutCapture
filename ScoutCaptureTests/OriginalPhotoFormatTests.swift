import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import ScoutCapture

final class OriginalPhotoFormatTests: XCTestCase {
    func testPreviousGalleryKeepsLatestRecordForDuplicateLocalPhoto() {
        let path = "/photos/shared.heic"
        let older = ReportAsset(
            localIdentifier: path,
            fileURL: URL(fileURLWithPath: path),
            creationDate: Date(timeIntervalSinceReferenceDate: 100),
            pixelWidth: 0,
            pixelHeight: 0,
            originalFilename: "older.heic"
        )
        let newer = ReportAsset(
            localIdentifier: path,
            fileURL: URL(fileURLWithPath: path),
            creationDate: Date(timeIntervalSinceReferenceDate: 200),
            pixelWidth: 0,
            pixelHeight: 0,
            originalFilename: "newer.heic"
        )

        let assets = ReportAsset.lastByLocalIdentifier(in: [older, newer])
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets[path], newer)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "OriginalPhotoFormatTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "scout.backup.automaticEnabled")
        return defaults
    }

    private func makeTempStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCapture-OriginalPhotoFormat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeShot(
        shotID: UUID,
        propertyID: UUID,
        sessionID: UUID,
        originalFilename: String,
        originalRelativePath: String
    ) -> ShotMetadata {
        ShotMetadata(
            shotID: shotID,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            capturedAtLocal: nil,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100),
            building: "Building",
            elevation: "North",
            detailType: "Overview",
            angleIndex: 1,
            trade: nil,
            priority: nil,
            shotKey: ShotMetadata.makeShotKey(building: "Building", elevation: "North", detailType: "Overview", angleIndex: 1),
            isGuided: true,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            captureKind: nil,
            firstCaptureKind: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: originalFilename,
            originalRelativePath: originalRelativePath,
            originalByteSize: 9,
            storageBucket: nil,
            storagePath: nil,
            checksumSHA256: nil,
            byteSize: 9,
            uploadState: "pending",
            uploadAttempts: 0,
            lastUploadError: nil,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            exifOrientation: nil,
            orientation: nil,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )
    }

    func testOriginalPhotoFormatDefaultsAreHighQualityJPEG() throws {
        let shotID = UUID()

        XCTAssertEqual(OriginalPhotoFormat.fileExtension, "jpg")
        XCTAssertEqual(OriginalPhotoFormat.utType, .jpeg)
        XCTAssertEqual(OriginalPhotoFormat.quality, 0.92, accuracy: 0.0001)
        XCTAssertEqual(OriginalPhotoFormat.defaultFilename(for: shotID), "\(shotID.uuidString).jpg")

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: OriginalPhotoFormat.quality))
        XCTAssertGreaterThan(data.count, 0)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try XCTUnwrap(CGImageSourceGetType(source))
        XCTAssertTrue(UTType(type as String)?.conforms(to: .jpeg) == true)
    }

    @MainActor
    func testStampedJPEGPreservesCaptureMetadataAndInvokesSelectedOverlay() throws {
        let propertyID = UUID()
        let sessionID = UUID()
        var shot = makeShot(
            shotID: UUID(),
            propertyID: propertyID,
            sessionID: sessionID,
            originalFilename: "original.jpg",
            originalRelativePath: "Originals/original.jpg"
        )
        shot.latitude = 40.5
        shot.longitude = -73.25
        shot.accuracyMeters = 3.5
        let context = ReportLibraryModel.stampedMetadataContext(
            propertyID: propertyID,
            propertyName: "Test Property",
            propertyAddress: nil,
            sessionID: sessionID,
            shot: shot,
            schemaVersion: 1
        )
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6)).image { renderer in
            UIColor.red.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        let sourceData = try XCTUnwrap(image.jpegData(compressionQuality: 0.92))
        var overlayCalled = false
        let stampedData = try encodeScoutStampedJPEG(
            from: sourceData,
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            overlayLines: ["Test Property", "North"],
            metadataContext: context,
            errorDomain: "ScoutCapture.Stamp",
            missingSourceDescription: "Missing source image for stamped export",
            logMetadata: false,
            drawOverlay: { cgImage, lines in
                overlayCalled = true
                XCTAssertEqual(lines, ["Test Property", "North"])
                return cgImage
            }
        )

        XCTAssertTrue(overlayCalled)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(stampedData as CFData, nil))
        let outputType = try XCTUnwrap(CGImageSourceGetType(source))
        XCTAssertTrue(UTType(outputType as String)?.conforms(to: .jpeg) == true)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        XCTAssertNotNil(exif[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue, 40.5)
        XCTAssertEqual((gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue, 73.25)
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "W")
        XCTAssertEqual((gps[kCGImagePropertyGPSHPositioningError] as? NSNumber)?.doubleValue, 3.5)
        XCTAssertEqual(gps[kCGImagePropertyGPSDateStamp] as? String, "2023:11:14")
        XCTAssertEqual(gps[kCGImagePropertyGPSTimeStamp] as? String, "22:13:20")

        let storageRoot = try makeTempStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let originalURL = storageRoot.appendingPathComponent("original.jpg")
        let stampedURL = storageRoot.appendingPathComponent("Stamped/stamped.jpg")
        try sourceData.write(to: originalURL)
        let captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        func writeStampedFile() throws {
            try writeScoutStampedJPEGIfMissing(
                sourceURL: originalURL,
                destinationURL: stampedURL,
                captureDate: captureDate,
                overlayLines: ["Test Property", "North"],
                metadataContext: context,
                fileManager: .default,
                errorDomain: "ScoutCapture.Stamp",
                missingSourceDescription: "Missing source image for stamped export",
                logMetadata: false,
                drawOverlay: { cgImage, _ in cgImage }
            )
        }
        try writeStampedFile()
        XCTAssertGreaterThan(try Data(contentsOf: stampedURL).count, 0)
        let modifiedAt = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: stampedURL.path)[.modificationDate] as? Date)
        XCTAssertEqual(modifiedAt.timeIntervalSince1970, captureDate.timeIntervalSince1970, accuracy: 1)
        try FileManager.default.removeItem(at: originalURL)
        try writeStampedFile() // A valid stamp is reused without rereading the source.
    }

    @MainActor
    func testStampedPhotoNamesAndOverlayKeepReadableDetails() {
        var shot = makeShot(
            shotID: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            originalFilename: "original.jpg",
            originalRelativePath: "Originals/original.jpg"
        )
        shot.building = "Roof / East"
        shot.elevation = "North"
        shot.detailType = "Overview"
        shot.isFlagged = true
        shot.noteText = "Needs review"
        var reservedNames: Set<String> = []

        let first = ScoutStampPresentation.nextReadableFilename(shot: shot, reservedNames: &reservedNames)
        let second = ScoutStampPresentation.nextReadableFilename(shot: shot, reservedNames: &reservedNames)
        XCTAssertTrue(first.hasPrefix("Roof__East_North_Overview_A1_"))
        XCTAssertTrue(first.hasSuffix(".jpg"))
        XCTAssertEqual(second, String(first.dropLast(4)) + "_01.jpg")

        let lines = ScoutStampPresentation.overlayLines(
            propertyName: " Test Property ",
            shot: shot,
            isBaselineSession: false
        )
        XCTAssertEqual(lines.first, "Test Property")
        XCTAssertEqual(lines.last, "Needs review")
        XCTAssertTrue(lines.contains("Roof / East | North | Overview | Angle 1"))
    }

    @MainActor
    func testUploadFallbackUsesJPGAndExplicitHEICIsPreserved() throws {
        let appState = AppState(userDefaults: makeDefaults(), disableCloudBackupForTests: true)
        defer { appState.shutdown() }

        let sessionID = UUID()
        let shotID = UUID()
        let fallbackPath = appState._debugOperationalMediaStoragePathForTests(
            sessionID: sessionID,
            shotID: shotID,
            originalFilename: ""
        )
        XCTAssertEqual(
            fallbackPath,
            "sessions/\(sessionID.uuidString.lowercased())/shots/\(shotID.uuidString.lowercased())/\(shotID.uuidString.lowercased()).jpg"
        )
        XCTAssertEqual(appState._debugContentTypeForTests(fileURL: URL(fileURLWithPath: fallbackPath)), "image/jpeg")

        let heicPath = appState._debugOperationalMediaStoragePathForTests(
            sessionID: sessionID,
            shotID: shotID,
            originalFilename: "legacy original.heic"
        )
        XCTAssertTrue(heicPath.hasSuffix("/legacy_original.heic"))
        XCTAssertEqual(appState._debugContentTypeForTests(fileURL: URL(fileURLWithPath: heicPath)), "image/heic")
    }

    @MainActor
    func testExportFallbackLooksForJPGThenLegacyHEICWithoutRenamingLegacyBytes() throws {
        let storageRoot = try makeTempStorageRoot()
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let localStore = LocalStore(testStorageRootURL: storageRoot)
        let orgID = UUID()
        let propertyID = UUID()
        let sessionID = UUID()
        let shotID = UUID()

        _ = try localStore.createOrganization(Organization(id: orgID, name: "Org"))
        _ = try localStore.createProperty(Property(id: propertyID, orgId: orgID, name: "Property", address: "123 Main"))
        _ = try localStore.upsertSession(Session(
            id: sessionID,
            propertyID: propertyID,
            startedAt: Date(timeIntervalSinceReferenceDate: 50),
            status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 70)
        ))
        try localStore.ensureSessionMetadata(for: Session(
            id: sessionID,
            propertyID: propertyID,
            startedAt: Date(timeIntervalSinceReferenceDate: 50),
            status: .completed,
            endedAt: Date(timeIntervalSinceReferenceDate: 70)
        ))

        let originals = localStore.originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let legacyURL = originals.appendingPathComponent(OriginalPhotoFormat.legacyHEICFilename(for: shotID), isDirectory: false)
        try Data("legacy-heic".utf8).write(to: legacyURL, options: .atomic)

        try localStore.upsertShot(
            propertyID: propertyID,
            sessionID: sessionID,
            shot: makeShot(shotID: shotID, propertyID: propertyID, sessionID: sessionID, originalFilename: "", originalRelativePath: ""),
            matchMode: .append
        )

        let metadata = try localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        let exports = localStore.exportOriginalFiles(for: metadata)

        XCTAssertEqual(exports.count, 1)
        XCTAssertEqual(exports[0].filename, OriginalPhotoFormat.legacyHEICFilename(for: shotID))
        XCTAssertEqual(exports[0].sourceURL.path, legacyURL.path)
    }
}
