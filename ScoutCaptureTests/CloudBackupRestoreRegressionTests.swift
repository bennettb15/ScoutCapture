import XCTest
import CryptoKit
@testable import ScoutCapture

final class CloudBackupRestoreRegressionTests: XCTestCase {
    private var managedBackupManagers: [CloudBackupManager] = []

    override func tearDown() {
        managedBackupManagers.forEach { $0.shutdown() }
        managedBackupManagers.removeAll()
        super.tearDown()
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoutCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeStorageRoot() throws -> URL {
        let root = try makeTempDirectory()
        let scout = root.appendingPathComponent("SCOUT", isDirectory: true)
        try FileManager.default.createDirectory(at: scout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scout.appendingPathComponent("Properties", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scout.appendingPathComponent("sessions", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scout.appendingPathComponent("observations", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scout.appendingPathComponent("guided-shots", isDirectory: true), withIntermediateDirectories: true)
        return root
    }

    private func writeProperties(_ properties: [Property], to storageRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(properties)
        let url = storageRoot.appendingPathComponent("SCOUT/properties.json", isDirectory: false)
        try data.write(to: url, options: .atomic)
    }

    private func writeOrganizations(_ organizations: [Organization], to storageRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(organizations)
        let url = storageRoot.appendingPathComponent("SCOUT/organizations.json", isDirectory: false)
        try data.write(to: url, options: .atomic)
    }

    private struct TombstoneDTO: Codable {
        let propertyID: UUID
        let deletedAt: Date
    }

    private func writeTombstones(_ tombstones: [TombstoneDTO], to storageRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tombstones)
        let url = storageRoot.appendingPathComponent("SCOUT/property-tombstones.json", isDirectory: false)
        try data.write(to: url, options: .atomic)
    }

    private func makeBackupManager() -> CloudBackupManager {
        let suite = "CloudBackupRestoreRegressionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "scout.backup.automaticEnabled")
        let manager = CloudBackupManager(userDefaults: defaults)
        managedBackupManagers.append(manager)
        return manager
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

    func testRestorePreflightDetectsMissingAndConflictingProperties() throws {
        let localRoot = try makeStorageRoot()
        let backupRoot = try makeStorageRoot()
        defer {
            try? FileManager.default.removeItem(at: localRoot)
            try? FileManager.default.removeItem(at: backupRoot)
        }

        let sharedID = UUID()
        let localOnlyID = UUID()
        let backupOnlyID = UUID()

        let localShared = Property(id: sharedID, name: "Local Name")
        let backupShared = Property(id: sharedID, name: "Backup Name")

        try writeProperties(
            [
                localShared,
                Property(id: localOnlyID, name: "Local Only")
            ],
            to: localRoot
        )
        try writeProperties(
            [
                backupShared,
                Property(id: backupOnlyID, name: "Backup Only")
            ],
            to: backupRoot
        )

        let manager = makeBackupManager()
        defer { manager.shutdown() }
        let preflight = try manager._debug_buildRestorePreflight(localStorageRoot: localRoot, backupStorageRoot: backupRoot)

        XCTAssertEqual(preflight.localPropertyCount, 2)
        XCTAssertEqual(preflight.backupPropertyCount, 2)
        XCTAssertEqual(preflight.matchingPropertyCount, 1)
        XCTAssertEqual(preflight.missingLocalPropertyIDs, [backupOnlyID])
        XCTAssertEqual(preflight.missingBackupPropertyIDs, [localOnlyID])
        XCTAssertEqual(preflight.conflictingPropertyIDs, [sharedID])
    }

    func testMergeMissingPropertiesCopiesIndexesAndMergesOrganizations() throws {
        let localRoot = try makeStorageRoot()
        let backupRoot = try makeStorageRoot()
        defer {
            try? FileManager.default.removeItem(at: localRoot)
            try? FileManager.default.removeItem(at: backupRoot)
        }

        let existingProperty = Property(id: UUID(), name: "Existing")
        let backupOrg = Organization(name: "Org A")
        let missingProperty = Property(id: UUID(), orgId: backupOrg.id, name: "Missing")

        try writeProperties([existingProperty], to: localRoot)
        try writeOrganizations([], to: localRoot)
        try writeProperties([existingProperty, missingProperty], to: backupRoot)
        try writeOrganizations([backupOrg], to: backupRoot)

        let backupScout = backupRoot.appendingPathComponent("SCOUT", isDirectory: true)
        let propertyFolder = backupScout
            .appendingPathComponent("Properties", isDirectory: true)
            .appendingPathComponent(missingProperty.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: propertyFolder, withIntermediateDirectories: true)
        let sessionFolder = propertyFolder
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        try Data("session-data".utf8).write(
            to: sessionFolder.appendingPathComponent("session.json", isDirectory: false),
            options: .atomic
        )

        let sessionIndexURL = backupScout
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(missingProperty.id.uuidString).json", isDirectory: false)
        try Data("[]".utf8).write(to: sessionIndexURL, options: .atomic)

        let manager = makeBackupManager()
        defer { manager.shutdown() }
        let preflight = try manager._debug_mergeMissingProperties(from: backupRoot, into: localRoot)
        XCTAssertEqual(preflight.missingLocalPropertyIDs, [missingProperty.id])

        let mergedProperties = try manager._debug_loadProperties(in: localRoot)
        XCTAssertEqual(Set(mergedProperties.map(\.id)), Set([existingProperty.id, missingProperty.id]))

        let localScout = localRoot.appendingPathComponent("SCOUT", isDirectory: true)
        let restoredFolder = localScout
            .appendingPathComponent("Properties", isDirectory: true)
            .appendingPathComponent(missingProperty.id.uuidString, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredFolder.path))

        let restoredSessionIndex = localScout
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(missingProperty.id.uuidString).json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredSessionIndex.path))

        let orgData = try Data(contentsOf: localScout.appendingPathComponent("organizations.json", isDirectory: false))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let organizations = try decoder.decode([Organization].self, from: orgData)
        XCTAssertEqual(organizations.map(\.id), [backupOrg.id])
    }

    func testMergeMissingPropertiesAppliesBackupTombstoneDeletes() throws {
        let localRoot = try makeStorageRoot()
        let backupRoot = try makeStorageRoot()
        defer {
            try? FileManager.default.removeItem(at: localRoot)
            try? FileManager.default.removeItem(at: backupRoot)
        }

        let retained = Property(id: UUID(), name: "Keep")
        let deleted = Property(id: UUID(), name: "DeleteMe")

        try writeProperties([retained, deleted], to: localRoot)
        try writeProperties([retained], to: backupRoot)

        let localScout = localRoot.appendingPathComponent("SCOUT", isDirectory: true)
        let deletedFolder = localScout
            .appendingPathComponent("Properties", isDirectory: true)
            .appendingPathComponent(deleted.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: deletedFolder, withIntermediateDirectories: true)
        let deletedSessionIndex = localScout
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(deleted.id.uuidString).json", isDirectory: false)
        try Data("[]".utf8).write(to: deletedSessionIndex, options: .atomic)

        try writeTombstones([TombstoneDTO(propertyID: deleted.id, deletedAt: Date())], to: backupRoot)

        let manager = makeBackupManager()
        defer { manager.shutdown() }
        _ = try manager._debug_mergeMissingProperties(from: backupRoot, into: localRoot)

        let merged = try manager._debug_loadProperties(in: localRoot)
        XCTAssertEqual(Set(merged.map(\.id)), Set([retained.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedFolder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedSessionIndex.path))

        let tombstoneURL = localScout.appendingPathComponent("property-tombstones.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstoneURL.path))
        let data = try Data(contentsOf: tombstoneURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let tombstones = try decoder.decode([TombstoneDTO].self, from: data)
        XCTAssertEqual(tombstones.map(\.propertyID), [deleted.id])
    }
}
