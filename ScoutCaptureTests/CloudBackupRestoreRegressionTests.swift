import XCTest
import CryptoKit
@testable import ScoutCapture

final class CloudBackupRestoreRegressionTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testRestoreMaterializationUsesBlobContentPathForSchemaV2() throws {
        let fileManager = FileManager.default
        let backupRoot = try makeTempDirectory()
        defer { try? fileManager.removeItem(at: backupRoot) }

        let sourceData = Data("blob-content".utf8)
        let sha = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        let blobRelativePath = CloudBackupDedupeSupport.blobRelativePath(for: sha)
        let blobURL = backupRoot.appendingPathComponent(blobRelativePath)
        try fileManager.createDirectory(at: blobURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sourceData.write(to: blobURL)

        let logicalRelativePath = "storage-root/SCOUT/Properties/P1/Sessions/S1/Originals/photo.heic"
        let manifest = CloudBackupManifest(
            backupID: UUID(),
            createdAt: Date(),
            schemaVersion: 2,
            appVersion: "test",
            localRevision: "r1",
            selectedPropertyID: nil,
            files: [
                .init(
                    relativePath: logicalRelativePath,
                    byteCount: sourceData.count,
                    sha256: sha,
                    contentRelativePath: blobRelativePath
                )
            ]
        )

        let destination = try makeTempDirectory().appendingPathComponent("storage-root", isDirectory: true)
        defer { try? fileManager.removeItem(at: destination.deletingLastPathComponent()) }

        try CloudBackupDedupeSupport.materializeStorageRoot(
            fileManager: fileManager,
            backupFolder: backupRoot,
            manifest: manifest,
            destinationStorageRoot: destination,
            ensureAvailable: { fileManager.fileExists(atPath: $0.path) }
        )

        let restoredURL = destination.appendingPathComponent("SCOUT/Properties/P1/Sessions/S1/Originals/photo.heic")
        XCTAssertTrue(fileManager.fileExists(atPath: restoredURL.path))
        XCTAssertEqual(try Data(contentsOf: restoredURL), sourceData)
    }

    func testRestoreMaterializationFallsBackToLogicalPathForSchemaV1() throws {
        let fileManager = FileManager.default
        let backupRoot = try makeTempDirectory()
        defer { try? fileManager.removeItem(at: backupRoot) }

        let sourceData = Data("legacy-content".utf8)
        let logicalRelativePath = "storage-root/SCOUT/Properties/P2/Sessions/S2/session.json"
        let sourceURL = backupRoot.appendingPathComponent(logicalRelativePath)
        try fileManager.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sourceData.write(to: sourceURL)

        let sha = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        let manifest = CloudBackupManifest(
            backupID: UUID(),
            createdAt: Date(),
            schemaVersion: 1,
            appVersion: "test",
            localRevision: "r1",
            selectedPropertyID: nil,
            files: [
                .init(
                    relativePath: logicalRelativePath,
                    byteCount: sourceData.count,
                    sha256: sha,
                    contentRelativePath: nil
                )
            ]
        )

        let destination = try makeTempDirectory().appendingPathComponent("storage-root", isDirectory: true)
        defer { try? fileManager.removeItem(at: destination.deletingLastPathComponent()) }

        try CloudBackupDedupeSupport.materializeStorageRoot(
            fileManager: fileManager,
            backupFolder: backupRoot,
            manifest: manifest,
            destinationStorageRoot: destination,
            ensureAvailable: { fileManager.fileExists(atPath: $0.path) }
        )

        let restoredURL = destination.appendingPathComponent("SCOUT/Properties/P2/Sessions/S2/session.json")
        XCTAssertTrue(fileManager.fileExists(atPath: restoredURL.path))
        XCTAssertEqual(try Data(contentsOf: restoredURL), sourceData)
    }

    func testDedupeClassificationAndResolvedPathLogic() {
        XCTAssertTrue(CloudBackupDedupeSupport.shouldStoreAsDeduplicatedBlob(relativePath: "SCOUT/a/b/photo.heic"))
        XCTAssertTrue(CloudBackupDedupeSupport.shouldStoreAsDeduplicatedBlob(relativePath: "SCOUT/a/b/video.mp4"))
        XCTAssertFalse(CloudBackupDedupeSupport.shouldStoreAsDeduplicatedBlob(relativePath: "SCOUT/a/b/session.json"))

        let recordWithContent = CloudBackupManifest.FileRecord(
            relativePath: "storage-root/SCOUT/a.heic",
            byteCount: 1,
            sha256: "abc",
            contentRelativePath: "blobs/aa/bb/hash"
        )
        XCTAssertEqual(CloudBackupDedupeSupport.resolvedContentRelativePath(for: recordWithContent), "blobs/aa/bb/hash")

        let recordWithoutContent = CloudBackupManifest.FileRecord(
            relativePath: "storage-root/SCOUT/a.heic",
            byteCount: 1,
            sha256: "abc",
            contentRelativePath: nil
        )
        XCTAssertEqual(
            CloudBackupDedupeSupport.resolvedContentRelativePath(for: recordWithoutContent),
            "storage-root/SCOUT/a.heic"
        )
    }
}
