import Foundation

enum StorageRoot {
    struct ExportZipEntry {
        let path: String
        let data: Data
        let modifiedAt: Date?
    }

    struct LegacyCloudStorageCleanupResult: Equatable {
        let rootPath: String
        let removedItemCount: Int
        let removedByteCount: Int
    }

    struct StorageBreakdownItem: Equatable, Identifiable {
        let id: String
        let title: String
        let path: String
        let itemCount: Int
        let byteCount: Int
    }

    struct LocalStorageBreakdownResult: Equatable {
        let generatedAt: Date
        let items: [StorageBreakdownItem]
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

    nonisolated static func clearLegacyCloudStorage() throws -> LegacyCloudStorageCleanupResult {
        guard let cloudRoot = resolve().cloudRoot else {
            return LegacyCloudStorageCleanupResult(rootPath: "", removedItemCount: 0, removedByteCount: 0)
        }

        let snapshot = try legacyCloudStorageSnapshot(at: cloudRoot)
        guard fileManager.fileExists(atPath: cloudRoot.path) else {
            return snapshot
        }

        let children = try fileManager.contentsOfDirectory(
            at: cloudRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for child in children {
            try fileManager.removeItem(at: child)
        }
        return snapshot
    }

    nonisolated static func localStorageBreakdown() throws -> LocalStorageBreakdownResult {
        let resolution = resolve()
        let appSupportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let activeRoot = resolution.activeRoot
        let scoutRoot = activeRoot.appendingPathComponent("SCOUT", isDirectory: true)
        let propertiesRoot = scoutRoot.appendingPathComponent("Properties", isDirectory: true)
        let archivesRoot = scoutRoot.appendingPathComponent("Archives", isDirectory: true)
        let fastLaneDraftRoot = appSupportRoot.appendingPathComponent("ScoutCaptureFastRuntimeDrafts", isDirectory: true)
        let fastLaneTempRoot = fileManager.temporaryDirectory.appendingPathComponent("ScoutCaptureFastRuntimePrototype", isDirectory: true)

        var items: [StorageBreakdownItem] = []
        items.append(try storageBreakdownItem(title: "Active Local Store", id: "active", url: activeRoot))
        items.append(try storageBreakdownItem(title: "SCOUT Data", id: "scout", url: scoutRoot))
        items.append(try storageBreakdownItem(title: "Live Property Files", id: "properties", url: propertiesRoot))
        items.append(try storageBreakdownItem(title: "Completed Archives", id: "archives", url: archivesRoot))
        items.append(try storageBreakdownItem(title: "Fast-Lane Drafts", id: "fastLaneDrafts", url: fastLaneDraftRoot))
        items.append(try storageBreakdownItem(title: "Fast-Lane Temp", id: "fastLaneTemp", url: fastLaneTempRoot))
        items.append(try storageBreakdownItem(
            title: "All Originals",
            id: "originals",
            urls: [propertiesRoot, archivesRoot, fastLaneDraftRoot],
            matchingPathComponent: "Originals"
        ))

        return LocalStorageBreakdownResult(
            generatedAt: Date(),
            items: items
        )
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

    private nonisolated static func legacyCloudStorageSnapshot(at root: URL) throws -> LegacyCloudStorageCleanupResult {
        guard fileManager.fileExists(atPath: root.path) else {
            return LegacyCloudStorageCleanupResult(rootPath: root.path, removedItemCount: 0, removedByteCount: 0)
        }

        let metrics = storageMetrics(in: root)

        return LegacyCloudStorageCleanupResult(
            rootPath: root.path,
            removedItemCount: metrics.itemCount,
            removedByteCount: metrics.byteCount
        )
    }

    private nonisolated static func storageBreakdownItem(
        title: String,
        id: String,
        url: URL
    ) throws -> StorageBreakdownItem {
        let metrics = storageMetrics(in: url)
        return StorageBreakdownItem(
            id: id,
            title: title,
            path: url.path,
            itemCount: metrics.itemCount,
            byteCount: metrics.byteCount
        )
    }

    private nonisolated static func storageBreakdownItem(
        title: String,
        id: String,
        urls: [URL],
        matchingPathComponent: String
    ) throws -> StorageBreakdownItem {
        var itemCount = 0
        var byteCount = 0
        let normalizedComponent = matchingPathComponent.lowercased()
        for url in urls {
            let metrics = storageMetrics(in: url) { fileURL in
                fileURL.pathComponents.contains { $0.lowercased() == normalizedComponent }
            }
            itemCount += metrics.itemCount
            byteCount += metrics.byteCount
        }

        return StorageBreakdownItem(
            id: id,
            title: title,
            path: urls.map(\.path).joined(separator: "\n"),
            itemCount: itemCount,
            byteCount: byteCount
        )
    }

    private nonisolated static func storageMetrics(
        in root: URL,
        include: (URL) -> Bool = { _ in true }
    ) -> (itemCount: Int, byteCount: Int) {
        guard fileManager.fileExists(atPath: root.path) else { return (0, 0) }
        var itemCount = 0
        var byteCount = 0
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator where include(fileURL) {
                itemCount += 1
                let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
                if values?.isRegularFile == true {
                    byteCount += values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
                }
            }
        }
        return (itemCount, byteCount)
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
