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

    static func entryPaths(at url: URL) throws -> [String] {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count >= 22 else { throw ArchiveError.invalidArchive }
        let lowerBound = max(0, bytes.count - 22 - Int(UInt16.max))
        guard let eocd = stride(from: bytes.count - 22, through: lowerBound, by: -1).first(where: {
            bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 0x05 && bytes[$0 + 3] == 0x06
        }) else { throw ArchiveError.invalidArchive }
        let count = int16(bytes, at: eocd + 10)
        var cursor = int32(bytes, at: eocd + 16)
        var paths: [String] = []
        paths.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor >= 0, cursor + 46 <= bytes.count,
                  int32(bytes, at: cursor) == 0x02014B50 else { throw ArchiveError.invalidArchive }
            let nameLength = int16(bytes, at: cursor + 28)
            let extraLength = int16(bytes, at: cursor + 30)
            let commentLength = int16(bytes, at: cursor + 32)
            let nameStart = cursor + 46
            let next = nameStart + nameLength + extraLength + commentLength
            guard next <= bytes.count,
                  let name = String(bytes: bytes[nameStart..<(nameStart + nameLength)], encoding: .utf8) else {
                throw ArchiveError.invalidArchive
            }
            paths.append(name)
            cursor = next
        }
        return paths
    }

    private static func int16(_ bytes: [UInt8], at index: Int) -> Int {
        Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
    }

    private static func int32(_ bytes: [UInt8], at index: Int) -> Int {
        int16(bytes, at: index) | (int16(bytes, at: index + 2) << 16)
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
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

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
