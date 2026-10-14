import Foundation

/// ZIP32 stored entries used by the current export flows. Media remains uncompressed.
enum StoredZipArchive {
    enum ArchiveError: Error {
        case exceedsZip32Limits
        case invalidArchive
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
        let fileSize = try input.seekToEnd()
        guard fileSize >= 22 else { throw ArchiveError.invalidArchive }
        let tailSize = min(fileSize, UInt64(UInt16.max) + 22)
        try input.seek(toOffset: fileSize - tailSize)
        let tail = [UInt8](try readExactly(Int(tailSize), from: input))
        guard let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail[$0] == 0x50 && tail[$0 + 1] == 0x4B && tail[$0 + 2] == 0x05 && tail[$0 + 3] == 0x06 &&
            $0 + 22 + int16(tail, at: $0 + 20) == tail.count
        }) else { throw ArchiveError.invalidArchive }
        let count = int16(tail, at: eocd + 10)
        let centralOffset = UInt64(int32(tail, at: eocd + 16))
        let centralSize = UInt64(int32(tail, at: eocd + 12))
        let centralEnd = centralOffset + centralSize
        guard centralEnd <= fileSize - tailSize + UInt64(eocd) else {
            throw ArchiveError.invalidArchive
        }
        try input.seek(toOffset: centralOffset)
        var cursor = centralOffset
        var paths: [String] = []
        paths.reserveCapacity(count)
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
            paths.append(name)
            try input.seek(toOffset: next)
            cursor = next
        }
        return paths
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
