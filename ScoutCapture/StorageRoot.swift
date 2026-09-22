import Foundation

enum StorageRoot {
    struct ExportZipEntry {
        let path: String
        let data: Data
        let modifiedAt: Date?
    }

    private struct Resolution {
        let cloudRoot: URL?
        let localRoot: URL

        nonisolated var activeRoot: URL {
            localRoot
        }
    }

    private nonisolated(unsafe) static let fileManager = FileManager.default
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var cachedResolution: Resolution?
    private nonisolated(unsafe) static var didLogStatus = false

    nonisolated static func activeRootURL() -> URL {
        resolve().activeRoot
    }

    nonisolated static func scoutRootURL() -> URL {
        activeRootURL().appendingPathComponent("SCOUT", isDirectory: true)
    }

    nonisolated static func scoutRootCandidates() -> [URL] {
        let resolution = resolve()
        var candidates: [URL] = [resolution.activeRoot.appendingPathComponent("SCOUT", isDirectory: true)]

        let localScoutRoot = resolution.localRoot.appendingPathComponent("SCOUT", isDirectory: true)
        if !candidates.contains(localScoutRoot) {
            candidates.append(localScoutRoot)
        }

        if let cloudRoot = resolution.cloudRoot {
            let cloudScoutRoot = cloudRoot.appendingPathComponent("SCOUT", isDirectory: true)
            if !candidates.contains(cloudScoutRoot) {
                candidates.append(cloudScoutRoot)
            }
        }

        return candidates
    }

    nonisolated static func cloudBackupRootURL() -> URL? {
        resolve().cloudRoot?.appendingPathComponent("Backups", isDirectory: true)
    }

    @discardableResult
    nonisolated static func prepareStorage() -> URL {
        lock.lock()
        defer { lock.unlock() }

        let timeout: TimeInterval = Thread.isMainThread ? 0 : 15.0
        let resolution = cachedResolution ?? makeResolution(timeout: timeout)
        cachedResolution = resolution

        let activeRoot = resolution.activeRoot
        let cloudAvailable = resolution.cloudRoot != nil

        do {
            try fileManager.createDirectory(at: activeRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: activeRoot
                    .appendingPathComponent("SCOUT", isDirectory: true)
                    .appendingPathComponent("Properties", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            print("[iCloud] storage prepare failed=\(error)")
        }

        if !didLogStatus {
            print("[iCloud] cloudAvailable=\(cloudAvailable)")
            print("[iCloud] activeRoot=\(activeRoot.path)")
            print("[iCloud] operationalStorage=local_app_support")
            didLogStatus = true
        }

        return activeRoot
    }

    private nonisolated static func resolve() -> Resolution {
        lock.lock()
        defer { lock.unlock() }

        if let cachedResolution {
            return cachedResolution
        }

        let timeout: TimeInterval = Thread.isMainThread ? 0 : 15.0
        let resolution = makeResolution(timeout: timeout)
        cachedResolution = resolution
        return resolution
    }

    private nonisolated static func makeResolution(timeout: TimeInterval = 15.0) -> Resolution {
        let localRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoutCapture", isDirectory: true)
        let cloudRoot = resolvedCloudRootWithRetry(timeout: timeout)
        return Resolution(cloudRoot: cloudRoot, localRoot: localRoot)
    }

    private nonisolated static func resolvedCloudRootWithRetry(timeout: TimeInterval) -> URL? {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while Date() < deadline {
            if let root = fileManager.url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("ScoutCapture", isDirectory: true) {
                return root
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return fileManager.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("ScoutCapture", isDirectory: true)
    }

    nonisolated static func makeSessionExportRootFolder(propertyFolderName: String, sessionID: UUID) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ScoutCapture-Exports", isDirectory: true)
            .appendingPathComponent(propertyFolderName, isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString)", isDirectory: true)

        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    nonisolated static func zipEntriesForExportRoot(_ root: URL) throws -> [ExportZipEntry] {
        var entries: [ExportZipEntry] = []
        let propertyFolderName = root.deletingLastPathComponent().lastPathComponent
        try appendZipEntries(in: root, relativeBase: propertyFolderName, to: &entries)
        return entries.sorted { $0.path < $1.path }
    }

    nonisolated static func exportRootFilenames(_ root: URL) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: root.path).sorted()
    }

    private nonisolated static func appendZipEntries(
        in directory: URL,
        relativeBase: String,
        to entries: inout [ExportZipEntry]
    ) throws {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey]
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for child in children {
            let values = try child.resourceValues(forKeys: resourceKeys)
            let relativePath = relativeBase.isEmpty ? child.lastPathComponent : "\(relativeBase)/\(child.lastPathComponent)"
            if values.isDirectory == true {
                entries.append(
                    ExportZipEntry(
                        path: "\(relativePath)/",
                        data: Data(),
                        modifiedAt: values.contentModificationDate ?? values.creationDate
                    )
                )
                try appendZipEntries(in: child, relativeBase: relativePath, to: &entries)
            } else {
                entries.append(
                    ExportZipEntry(
                        path: relativePath,
                        data: try Data(contentsOf: child),
                        modifiedAt: values.contentModificationDate ?? values.creationDate
                    )
                )
            }
        }
    }
}
