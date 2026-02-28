import Foundation

enum StorageRoot {
    private struct Resolution {
        let cloudRoot: URL?
        let localRoot: URL

        var activeRoot: URL {
            cloudRoot ?? localRoot
        }
    }

    private static let fileManager = FileManager.default
    private static let lock = NSLock()
    private static var cachedResolution: Resolution?
    private static var didPrepareStorage = false
    private static var didLogStatus = false

    static func activeRootURL() -> URL {
        resolve().activeRoot
    }

    static func scoutRootURL() -> URL {
        activeRootURL().appendingPathComponent("SCOUT", isDirectory: true)
    }

    static func scoutRootCandidates() -> [URL] {
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

    @discardableResult
    static func prepareStorage() -> URL {
        lock.lock()
        defer { lock.unlock() }

        let resolution = cachedResolution ?? makeResolution()
        cachedResolution = resolution

        let cloudAvailable = resolution.cloudRoot != nil
        let activeRoot = resolution.activeRoot
        let didAttemptMigration: Bool
        let migrationResult: String

        if didPrepareStorage {
            didAttemptMigration = false
            migrationResult = "skipped"
        } else {
            let outcome = migrateLocalSCOUTToCloudIfNeeded(using: resolution)
            didAttemptMigration = outcome.attempted
            migrationResult = outcome.result
            didPrepareStorage = true
        }

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
            print("[iCloud] migration attempted=\(didAttemptMigration)")
            print("[iCloud] migration result=\(migrationResult)")
            didLogStatus = true
        }

        return activeRoot
    }

    private static func resolve() -> Resolution {
        lock.lock()
        defer { lock.unlock() }

        if let cachedResolution {
            return cachedResolution
        }

        let resolution = makeResolution()
        cachedResolution = resolution
        return resolution
    }

    private static func makeResolution() -> Resolution {
        let localRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoutCapture", isDirectory: true)
        let cloudRoot = fileManager.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("ScoutCapture", isDirectory: true)
        return Resolution(cloudRoot: cloudRoot, localRoot: localRoot)
    }

    private static func migrateLocalSCOUTToCloudIfNeeded(using resolution: Resolution) -> (attempted: Bool, result: String) {
        guard let cloudRoot = resolution.cloudRoot else {
            return (false, "skipped")
        }

        let localScoutRoot = resolution.localRoot.appendingPathComponent("SCOUT", isDirectory: true)
        let cloudScoutRoot = cloudRoot.appendingPathComponent("SCOUT", isDirectory: true)

        guard fileManager.fileExists(atPath: localScoutRoot.path) else {
            return (false, "skipped")
        }

        if fileManager.fileExists(atPath: cloudScoutRoot.path) {
            return (true, "alreadyPresent")
        }

        do {
            try fileManager.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
            try fileManager.copyItem(at: localScoutRoot, to: cloudScoutRoot)

            guard fileManager.fileExists(atPath: cloudScoutRoot.path) else {
                return (true, "failed(copyVerifyMissing)")
            }

            do {
                try fileManager.removeItem(at: localScoutRoot)
                return (true, "deletedLocal")
            } catch {
                return (true, "copied")
            }
        } catch {
            return (true, "failed(\(error.localizedDescription))")
        }
    }
}
