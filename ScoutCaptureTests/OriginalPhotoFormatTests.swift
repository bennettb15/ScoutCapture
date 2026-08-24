import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import ScoutCapture

final class OriginalPhotoFormatTests: XCTestCase {
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
