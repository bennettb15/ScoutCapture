import Foundation

/// ZIP32 stored entries used by the current export flows. Media remains uncompressed.
enum StoredZipArchive {
    enum ArchiveError: Error {
        case exceedsZip32Limits
        case invalidArchive
        case unsupportedArchive
    }

    struct Entry {
        let path: String
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    static func buildData(entries: [(path: String, data: Data)]) throws -> Data {
        try buildData(entries: entries.map { (path: $0.path, data: $0.data, modifiedAt: nil) }, timestamped: false)
    }

    static func buildData(
        entries: [(path: String, data: Data, modifiedAt: Date?)],
        timestamped: Bool = true
    ) throws -> Data {
        struct CentralRecord {
            let pathData: Data
            let crc32: UInt32
            let size: UInt32
            let localHeaderOffset: UInt32
            let dosTime: UInt16
            let dosDate: UInt16
        }

        guard entries.count <= Int(UInt16.max) else { throw ArchiveError.exceedsZip32Limits }
        var zip = Data()
        var records: [CentralRecord] = []
        records.reserveCapacity(entries.count)

        for entry in entries {
            let pathData = Data(entry.path.utf8)
            guard let nameLength = UInt16(exactly: pathData.count),
                  let size = UInt32(exactly: entry.data.count),
                  let localOffset = UInt32(exactly: zip.count) else {
                throw ArchiveError.exceedsZip32Limits
            }
            let (dosTime, dosDate) = timestamped ? dosDateTime(entry.modifiedAt ?? Date()) : (0, 0)
            let checksum = crc32(entry.data)

            appendUInt32LE(0x04034B50, to: &zip)
            appendUInt16LE(20, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(dosTime, to: &zip)
            appendUInt16LE(dosDate, to: &zip)
            appendUInt32LE(checksum, to: &zip)
            appendUInt32LE(size, to: &zip)
            appendUInt32LE(size, to: &zip)
            appendUInt16LE(nameLength, to: &zip)
            appendUInt16LE(0, to: &zip)
            zip.append(pathData)
            zip.append(entry.data)
            records.append(CentralRecord(
                pathData: pathData, crc32: checksum, size: size,
                localHeaderOffset: localOffset, dosTime: dosTime, dosDate: dosDate
            ))
        }

        guard let centralOffset = UInt32(exactly: zip.count) else { throw ArchiveError.exceedsZip32Limits }
        for record in records {
            appendUInt32LE(0x02014B50, to: &zip)
            appendUInt16LE(20, to: &zip)
            appendUInt16LE(20, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(record.dosTime, to: &zip)
            appendUInt16LE(record.dosDate, to: &zip)
            appendUInt32LE(record.crc32, to: &zip)
            appendUInt32LE(record.size, to: &zip)
            appendUInt32LE(record.size, to: &zip)
            appendUInt16LE(UInt16(record.pathData.count), to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt32LE(0, to: &zip)
            appendUInt32LE(record.localHeaderOffset, to: &zip)
            zip.append(record.pathData)
        }

        guard let centralSize = UInt32(exactly: zip.count - Int(centralOffset)) else {
            throw ArchiveError.exceedsZip32Limits
        }
        let count = UInt16(records.count)
        appendUInt32LE(0x06054B50, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(count, to: &zip)
        appendUInt16LE(count, to: &zip)
        appendUInt32LE(centralSize, to: &zip)
        appendUInt32LE(centralOffset, to: &zip)
        appendUInt16LE(0, to: &zip)
        return zip
    }

    /// Writes one media file at a time, keeping archive size out of process memory.
    static func writeFileArchive(
        entries: [StorageRoot.ExportZipEntry],
        at url: URL,
        timestamped: Bool = true
    ) throws {
        try writeFileArchive(
            entries: entries.map { (path: $0.path, fileURL: $0.fileURL, modifiedAt: $0.modifiedAt) },
            at: url,
            timestamped: timestamped
        )
    }

    nonisolated static func writeFileArchive(
        entries: [(path: String, fileURL: URL?, modifiedAt: Date?)],
        at url: URL,
        timestamped: Bool = true,
        onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws {
        struct CentralRecord {
            let pathData: Data
            let crc32: UInt32
            let size: UInt32
            let offset: UInt32
            let dosTime: UInt16
            let dosDate: UInt16
        }

        guard entries.count <= Int(UInt16.max) else { throw ArchiveError.exceedsZip32Limits }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: url)
        do {
            var records: [CentralRecord] = []
            records.reserveCapacity(entries.count)
            var offset: UInt64 = 0
            for entry in entries {
                let pathData = Data(entry.path.utf8)
                guard let nameLength = UInt16(exactly: pathData.count),
                      let localOffset = UInt32(exactly: offset) else {
                    throw ArchiveError.exceedsZip32Limits
                }
                let (checksum, size) = try entry.fileURL.map(fileCRC32AndSize) ?? (0, 0)
                let (dosTime, dosDate) = timestamped ? dosDateTime(entry.modifiedAt ?? Date()) : (0, 0)
                var header = Data()
                appendUInt32LE(0x04034B50, to: &header)
                appendUInt16LE(20, to: &header)
                appendUInt16LE(0, to: &header)
                appendUInt16LE(0, to: &header)
                appendUInt16LE(dosTime, to: &header)
                appendUInt16LE(dosDate, to: &header)
                appendUInt32LE(checksum, to: &header)
                appendUInt32LE(size, to: &header)
                appendUInt32LE(size, to: &header)
                appendUInt16LE(nameLength, to: &header)
                appendUInt16LE(0, to: &header)
                header.append(pathData)
                try output.write(contentsOf: header)
                offset += UInt64(header.count)
                if let source = entry.fileURL {
                    let copied = try copyFile(from: source, to: output)
                    guard copied == UInt64(size) else { throw ArchiveError.invalidArchive }
                    offset += copied
                }
                records.append(CentralRecord(
                    pathData: pathData, crc32: checksum, size: size, offset: localOffset,
                    dosTime: dosTime, dosDate: dosDate
                ))
                onProgress(records.count, entries.count)
            }

            guard let centralOffset = UInt32(exactly: offset) else { throw ArchiveError.exceedsZip32Limits }
            for record in records {
                var header = Data()
                appendUInt32LE(0x02014B50, to: &header)
                appendUInt16LE(20, to: &header)
                appendUInt16LE(20, to: &header)
                appendUInt16LE(0, to: &header)
                appendUInt16LE(0, to: &header)
                appendUInt16LE(record.dosTime, to: &header)
                appendUInt16LE(record.dosDate, to: &header)
                appendUInt32LE(record.crc32, to: &header)
                appendUInt32LE(record.size, to: &header)
                appendUInt32LE(record.size, to: &header)
                appendUInt16LE(UInt16(record.pathData.count), to: &header)
                appendUInt16LE(0, to: &header)
                appendUInt16LE(0, to: &header)
                appendUInt16LE(0, to: &header)
                appendUInt16LE(0, to: &header)
                appendUInt32LE(0, to: &header)
                appendUInt32LE(record.offset, to: &header)
                header.append(record.pathData)
                try output.write(contentsOf: header)
                offset += UInt64(header.count)
            }
            guard let centralSize = UInt32(exactly: offset - UInt64(centralOffset)),
                  UInt32(exactly: offset) != nil else {
                throw ArchiveError.exceedsZip32Limits
            }
            var end = Data()
            let count = UInt16(records.count)
            appendUInt32LE(0x06054B50, to: &end)
            appendUInt16LE(0, to: &end)
            appendUInt16LE(0, to: &end)
            appendUInt16LE(count, to: &end)
            appendUInt16LE(count, to: &end)
            appendUInt32LE(centralSize, to: &end)
            appendUInt32LE(centralOffset, to: &end)
            appendUInt16LE(0, to: &end)
            try output.write(contentsOf: end)
            try output.close()
        } catch {
            try? output.close()
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    private nonisolated static func fileCRC32AndSize(_ url: URL) throws -> (UInt32, UInt32) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc: UInt32 = 0xFFFF_FFFF
        var size: UInt64 = 0
        while try autoreleasepool(invoking: {
            guard let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty else { return false }
            size += UInt64(chunk.count)
            guard size <= UInt64(UInt32.max) else { throw ArchiveError.exceedsZip32Limits }
            crc = updatingCRC32(crc, with: chunk)
            return true
        }) {}
        return (crc ^ 0xFFFF_FFFF, UInt32(size))
    }

    private nonisolated static func copyFile(from url: URL, to output: FileHandle) throws -> UInt64 {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var count: UInt64 = 0
        while try autoreleasepool(invoking: {
            guard let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty else { return false }
            try output.write(contentsOf: chunk)
            count += UInt64(chunk.count)
            return true
        }) {}
        return count
    }

    static func entryPaths(at url: URL) throws -> [String] {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        return try entries(from: input).map(\.path)
    }

    nonisolated static func entries(from input: FileHandle) throws -> [Entry] {
        let fileSize = try input.seekToEnd()
        guard fileSize >= 22 else { throw ArchiveError.unsupportedArchive }
        let tailSize = min(fileSize, UInt64(UInt16.max) + 22)
        try input.seek(toOffset: fileSize - tailSize)
        let tail = [UInt8](try readExactly(Int(tailSize), from: input))
        guard let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail[$0] == 0x50 && tail[$0 + 1] == 0x4B && tail[$0 + 2] == 0x05 && tail[$0 + 3] == 0x06 &&
            $0 + 22 + int16(tail, at: $0 + 20) == tail.count
        }) else { throw ArchiveError.unsupportedArchive }
        let count = int16(tail, at: eocd + 10)
        let centralOffset = UInt64(int32(tail, at: eocd + 16))
        let centralSize = UInt64(int32(tail, at: eocd + 12))
        let centralEnd = centralOffset + centralSize
        guard centralEnd <= fileSize - tailSize + UInt64(eocd) else {
            throw ArchiveError.invalidArchive
        }
        try input.seek(toOffset: centralOffset)
        var cursor = centralOffset
        var found: [Entry] = []
        found.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor + 46 <= centralEnd else { throw ArchiveError.invalidArchive }
            let header = [UInt8](try readExactly(46, from: input))
            guard int32(header, at: 0) == 0x02014B50 else { throw ArchiveError.invalidArchive }
            let nameLength = int16(header, at: 28)
            let extraLength = int16(header, at: 30)
            let commentLength = int16(header, at: 32)
            let next = cursor + 46 + UInt64(nameLength + extraLength + commentLength)
            guard next <= centralEnd else { throw ArchiveError.invalidArchive }
            let nameData = try readExactly(nameLength, from: input)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ArchiveError.invalidArchive
            }
            found.append(Entry(
                path: name,
                compressionMethod: UInt16(int16(header, at: 10)),
                crc32: UInt32(int32(header, at: 16)),
                compressedSize: UInt32(int32(header, at: 20)),
                uncompressedSize: UInt32(int32(header, at: 24)),
                localHeaderOffset: UInt32(int32(header, at: 42))
            ))
            try input.seek(toOffset: next)
            cursor = next
        }
        guard cursor == centralEnd else { throw ArchiveError.invalidArchive }
        return found
    }

    private static func readExactly(_ count: Int, from input: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let chunk = try input.read(upToCount: count - result.count), !chunk.isEmpty else {
                throw ArchiveError.invalidArchive
            }
            result.append(chunk)
        }
        return result
    }

    private static func int16(_ bytes: [UInt8], at index: Int) -> Int {
        Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
    }

    private static func int32(_ bytes: [UInt8], at index: Int) -> Int {
        int16(bytes, at: index) | (int16(bytes, at: index + 2) << 16)
    }

    private nonisolated static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let month = min(max(parts.month ?? 1, 1), 12)
        let day = min(max(parts.day ?? 1, 1), 31)
        let hour = min(max(parts.hour ?? 0, 0), 23)
        let minute = min(max(parts.minute ?? 0, 0), 59)
        let second = min(max(parts.second ?? 0, 0), 59)
        return (UInt16((hour << 11) | (minute << 5) | (second / 2)),
                UInt16(((year - 1980) << 9) | (month << 5) | day))
    }

    nonisolated static func updatingCRC32(_ checksum: UInt32, with data: Data) -> UInt32 {
        var crc = checksum
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc
    }

    private static func crc32(_ data: Data) -> UInt32 {
        updatingCRC32(0xFFFF_FFFF, with: data) ^ 0xFFFF_FFFF
    }

    private nonisolated static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private nonisolated static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

/// Shared packaging and path checks for normal and pending session exports.
enum SessionExportZip {
    struct Result {
        let url: URL
        let listedEntries: [String]
        let relativePaths: Set<String>
    }

    static func stageValidatedArtifacts(
        _ artifacts: LocalStore.ValidatedSessionExportArtifacts,
        from localStore: LocalStore,
        at exportRoot: URL,
        errorDomain: String,
        fileManager: FileManager = .default,
        onOriginalsCopied: () -> Void
    ) throws -> Set<String> {
        let originalsRoot = exportRoot.appendingPathComponent("Originals", isDirectory: true)
        var expectedPaths: Set<String> = [
            "session.json",
            "validation.txt",
            "sessions.csv",
            "shots.csv",
            "issues.csv",
            "issue_history.csv",
            "guided_rows.csv",
            "Originals/"
        ]
        for originalFile in artifacts.originalFiles {
            let attrs = try? fileManager.attributesOfItem(atPath: originalFile.sourceURL.path)
            let modifiedAt = (attrs?[.modificationDate] as? Date) ?? (attrs?[.creationDate] as? Date)
            let destinationURL = originalsRoot.appendingPathComponent(originalFile.filename)
            try fileManager.copyItem(at: originalFile.sourceURL, to: destinationURL)
            if let modifiedAt {
                try? fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: destinationURL.path)
            }
            expectedPaths.insert("Originals/\(originalFile.filename)")
        }
        onOriginalsCopied()
        try artifacts.sessionData.write(to: exportRoot.appendingPathComponent("session.json"), options: .atomic)
        try artifacts.validationData.write(to: exportRoot.appendingPathComponent("validation.txt"), options: .atomic)
        for csvFile in localStore.exportCSVFiles(for: artifacts.metadata) {
            try csvFile.data.write(to: exportRoot.appendingPathComponent(csvFile.filename), options: .atomic)
        }
        if !artifacts.prewritePassed || !artifacts.postwritePassed {
            let message = String(data: artifacts.validationData, encoding: .utf8) ?? "Export validation failed."
            throw NSError(
                domain: errorDomain,
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Export validation failed before ZIP creation.\n\n\(message)"]
            )
        }
        return expectedPaths
    }

    static func standardFilename(propertyName: String, propertyID: UUID?, sessionID: UUID?) -> String {
        let trimmedName = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmedName.isEmpty
            ? "ScoutCapture-Export"
            : trimmedName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
        let propertyPrefix = String((propertyID?.uuidString ?? "unknown").prefix(8))
        let sessionPrefix = String((sessionID?.uuidString ?? UUID().uuidString).prefix(8))
        return "\(safeName)_\(propertyPrefix)_\(sessionPrefix).zip"
    }

    static func package(
        exportRoot: URL,
        expectedPaths: Set<String>,
        finalURL: URL,
        errorDomain: String,
        fileManager: FileManager = .default
    ) throws -> Result {
        let zipEntries = try StorageRoot.zipEntriesForExportRoot(exportRoot)
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tmp.zip")
        defer {
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
        }
        if fileManager.fileExists(atPath: tempURL.path) {
            try fileManager.removeItem(at: tempURL)
        }
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try StoredZipArchive.writeFileArchive(entries: zipEntries, at: tempURL)
        let tempExists = fileManager.fileExists(atPath: tempURL.path)
        let tempSize = ((try? fileManager.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
        guard tempExists, tempSize > 0 else {
            throw NSError(domain: errorDomain, code: 5, userInfo: [NSLocalizedDescriptionKey: "Temporary ZIP write failed."])
        }

        try fileManager.moveItem(at: tempURL, to: finalURL)
        let finalExists = fileManager.fileExists(atPath: finalURL.path)
        let finalSize = ((try? fileManager.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
        guard finalExists, finalSize > 0 else {
            throw NSError(domain: errorDomain, code: 6, userInfo: [NSLocalizedDescriptionKey: "Final ZIP write failed."])
        }

        let listedEntries = try StoredZipArchive.entryPaths(at: finalURL)
        let zipRootFolderName = exportRoot.deletingLastPathComponent().lastPathComponent
        let normalizedExpectedPaths = Set(expectedPaths.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
        let actualPaths = Set(listedEntries.compactMap { path -> String? in
            let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalized.isEmpty else { return nil }
            if normalized == zipRootFolderName { return nil }
            let prefix = "\(zipRootFolderName)/"
            if normalized.hasPrefix(prefix) {
                return String(normalized.dropFirst(prefix.count))
            }
            return normalized
        })
        guard normalizedExpectedPaths.isSubset(of: actualPaths) else {
            throw NSError(domain: errorDomain, code: 7, userInfo: [NSLocalizedDescriptionKey: "ZIP integrity check failed."])
        }
        return Result(url: finalURL, listedEntries: listedEntries, relativePaths: actualPaths)
    }
}
