import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum TemporaryMigrationExportConstants {
    nonisolated static let exportRootFolderName = "ScoutCapture_Migration"
    nonisolated static let exportArchiveName = "ScoutCapture_Migration.zip"
    nonisolated static let userDefaultsFilename = "userdefaults_export.json"
    nonisolated static let applicationSupportFolderName = "Application Support"
    nonisolated static let documentsFolderName = "Documents"
}

struct TemporaryMigrationExportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var isPreparingExport: Bool = false
    @State private var shareItem: MigrationShareItem? = nil
    @State private var exportStatusMessage: String? = nil
    @State private var exportErrorMessage: String? = nil
    @State private var showExportError: Bool = false
    @State private var exportPhaseMessage: String = "Idle"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    warningCard

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Included Data")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)

                        includedRow("App Documents directory contents")
                        includedRow("Application Support directory contents")
                        includedRow("ScoutCapture-managed session folders, images, JSON, CSV, thumbnails, and related persisted files found in those roots")
                        includedRow("A JSON snapshot of UserDefaults / AppStorage values")
                        Text("Temporary note: iCloud ubiquity Documents are intentionally skipped in this migration pass to avoid long export stalls.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Button(action: beginExport) {
                            HStack {
                                if isPreparingExport {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.white)
                                }
                                Text(isPreparingExport ? "Preparing Migration Zip..." : "Export Migration Zip")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundColor(.white)
                            .background(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isPreparingExport)

                        Text("Creates a `ScoutCapture_Migration.zip` archive and opens the standard iOS share sheet so it can be saved to Files, iCloud Drive, AirDrop, or transferred to Finder for USB restore workflows.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)

                        Text("Status: \(exportPhaseMessage)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)

                        if let exportStatusMessage {
                            Text(exportStatusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.green)
                        }
                    }
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(16)
            }
            .navigationTitle("Archive Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $shareItem) { item in
            MigrationActivityShareSheet(activityItems: [item.url])
        }
        .alert("Migration Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportErrorMessage ?? "Unable to create the migration export zip.")
        }
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Internal Migration Use Only")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(warningLabelColor)

            Text("This is a temporary one-time export utility for moving data from the old app install into the new signed app later. Do not use this as a normal workflow feature.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(warningLabelColor.opacity(0.9))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(warningFillColor)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var warningFillColor: Color {
        colorScheme == .light ? Color.orange.opacity(0.18) : Color.orange.opacity(0.24)
    }

    private var warningLabelColor: Color {
        colorScheme == .light ? Color.orange.opacity(0.95) : Color.orange.opacity(0.88)
    }

    private func includedRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.blue)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 2)

            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func beginExport() {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        exportStatusMessage = nil
        exportErrorMessage = nil
        showExportError = false
        exportPhaseMessage = "Starting export..."

        Task.detached(priority: .userInitiated) {
            do {
                let exportArchiveURL = try TemporaryMigrationExportManager.createMigrationArchive { phase in
                    Task { @MainActor in
                        exportPhaseMessage = phase
                    }
                }
                await MainActor.run {
                    isPreparingExport = false
                    exportStatusMessage = "Migration zip prepared. Save it from the share sheet."
                    exportPhaseMessage = "Share sheet ready."
                    shareItem = MigrationShareItem(url: exportArchiveURL)
                }
            } catch {
                await MainActor.run {
                    isPreparingExport = false
                    exportErrorMessage = error.localizedDescription
                    exportPhaseMessage = "Export failed."
                    showExportError = true
                }
            }
        }
    }
}

private struct MigrationShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MigrationActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

enum TemporaryMigrationExportManager {
    nonisolated static func createMigrationArchive(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        onPhaseUpdate: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> URL {
        onPhaseUpdate("Creating temporary workspace...")
        let workspaceURL = fileManager.temporaryDirectory
            .appendingPathComponent("ScoutCaptureMigration-\(UUID().uuidString)", isDirectory: true)
        let exportRootURL = workspaceURL
            .appendingPathComponent(TemporaryMigrationExportConstants.exportRootFolderName, isDirectory: true)

        try fileManager.createDirectory(at: exportRootURL, withIntermediateDirectories: true)

        var copyFailures: [String] = []

        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        let activeStorageRootURL = StorageRoot.prepareStorage()

        if let documentsURL {
            onPhaseUpdate("Copying Documents...")
            copyDirectoryContentsIfPresent(
                from: documentsURL,
                to: exportRootURL.appendingPathComponent("Documents", isDirectory: true),
                label: "Documents",
                fileManager: fileManager,
                excludedTopLevelNames: [],
                failures: &copyFailures
            )
        }

        onPhaseUpdate("Copying active ScoutCapture storage...")
        copyDirectoryContentsIfPresent(
            from: activeStorageRootURL,
            to: exportRootURL.appendingPathComponent("Application Support", isDirectory: true),
            label: "Active ScoutCapture storage",
            fileManager: fileManager,
            excludedTopLevelNames: ["Backups"],
            failures: &copyFailures
        )

        onPhaseUpdate("Exporting UserDefaults...")
        let defaultsExportURL = exportRootURL
            .appendingPathComponent(TemporaryMigrationExportConstants.userDefaultsFilename)
        let defaultsData = try makeUserDefaultsExportData(userDefaults: userDefaults)
        try defaultsData.write(to: defaultsExportURL, options: [.atomic])

        onPhaseUpdate("Creating ZIP archive...")
        let archiveURL = workspaceURL.appendingPathComponent(TemporaryMigrationExportConstants.exportArchiveName)
        let entryCount = try buildZipArchive(
            at: archiveURL,
            from: exportRootURL,
            fileManager: fileManager,
            onProgress: { completed, total in
                onPhaseUpdate("Creating ZIP archive (\(completed)/\(total))...")
            }
        )
        onPhaseUpdate("Created ZIP archive with \(entryCount) entries.")

        if !copyFailures.isEmpty {
            print("[MigrationExport] completed with copy failures:")
            for failure in copyFailures {
                print("[MigrationExport] \(failure)")
            }
        } else {
            print("[MigrationExport] completed without copy failures.")
        }

        return archiveURL
    }

    private nonisolated static func copyDirectoryContentsIfPresent(
        from sourceURL: URL,
        to destinationURL: URL,
        label: String,
        fileManager: FileManager,
        excludedTopLevelNames: Set<String>,
        failures: inout [String]
    ) {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            print("[MigrationExport] \(label) not found at \(sourceURL.path)")
            return
        }

        do {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            try copyDirectoryContents(
                from: sourceURL,
                to: destinationURL,
                fileManager: fileManager,
                excludedTopLevelNames: excludedTopLevelNames,
                failures: &failures
            )
        } catch {
            let message = "\(label) root copy failed: \(sourceURL.path) error=\(error.localizedDescription)"
            failures.append(message)
            print("[MigrationExport] \(message)")
        }
    }

    private nonisolated static func copyDirectoryContents(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager,
        excludedTopLevelNames: Set<String>,
        failures: inout [String]
    ) throws {
        let children = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for childURL in children {
            if excludedTopLevelNames.contains(childURL.lastPathComponent) {
                continue
            }
            let resourceValues = try childURL.resourceValues(forKeys: [.isDirectoryKey])
            let targetURL = destinationURL.appendingPathComponent(childURL.lastPathComponent, isDirectory: resourceValues.isDirectory == true)

            if resourceValues.isDirectory == true {
                do {
                    try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
                    try copyDirectoryContents(
                        from: childURL,
                        to: targetURL,
                        fileManager: fileManager,
                        excludedTopLevelNames: [],
                        failures: &failures
                    )
                } catch {
                    let message = "Directory copy failed: \(childURL.path) error=\(error.localizedDescription)"
                    failures.append(message)
                    print("[MigrationExport] \(message)")
                }
            } else {
                do {
                    let parentURL = targetURL.deletingLastPathComponent()
                    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: targetURL.path) {
                        try? fileManager.removeItem(at: targetURL)
                    }
                    try fileManager.copyItem(at: childURL, to: targetURL)
                } catch {
                    let message = "File copy failed: \(childURL.path) error=\(error.localizedDescription)"
                    failures.append(message)
                    print("[MigrationExport] \(message)")
                }
            }
        }
    }

    private nonisolated static func makeUserDefaultsExportData(userDefaults: UserDefaults) throws -> Data {
        let rawDefaults = userDefaults.dictionaryRepresentation()
        let normalizedDefaults = normalizeJSONValue(rawDefaults) as? [String: Any] ?? [:]

        let payload: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "values": normalizedDefaults
        ]

        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private nonisolated static func normalizeJSONValue(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let float as Float:
            return float
        case let url as URL:
            return url.absoluteString
        case let data as Data:
            return [
                "type": "data",
                "base64": data.base64EncodedString()
            ]
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let array as [Any]:
            return array.map { normalizeJSONValue($0) }
        case let dictionary as [String: Any]:
            return dictionary.mapValues { normalizeJSONValue($0) }
        default:
            return String(describing: value)
        }
    }

    private struct ZipEntry {
        let path: String
        let fileURL: URL?
        let modifiedAt: Date
    }

    private struct ZipCentralDirectoryRecord {
        let pathData: Data
        let crc32: UInt32
        let size: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
        let localHeaderOffset: UInt32
    }

    private nonisolated static func makeZipEntries(rootURL: URL, fileManager: FileManager) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        let rootName = rootURL.lastPathComponent
        entries.append(ZipEntry(path: "\(rootName)/", fileURL: nil, modifiedAt: Date()))
        try appendZipEntries(in: rootURL, relativePath: rootName, fileManager: fileManager, entries: &entries)
        return entries
    }

    private nonisolated static func appendZipEntries(
        in directoryURL: URL,
        relativePath: String,
        fileManager: FileManager,
        entries: inout [ZipEntry]
    ) throws {
        let children = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for childURL in children {
            let values = try childURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey])
            let childRelativePath = "\(relativePath)/\(childURL.lastPathComponent)"
            let modifiedAt = values.contentModificationDate ?? values.creationDate ?? Date()

            if values.isDirectory == true {
                entries.append(ZipEntry(path: "\(childRelativePath)/", fileURL: nil, modifiedAt: modifiedAt))
                try appendZipEntries(
                    in: childURL,
                    relativePath: childRelativePath,
                    fileManager: fileManager,
                    entries: &entries
                )
            } else {
                entries.append(
                    ZipEntry(
                        path: childRelativePath,
                        fileURL: childURL,
                        modifiedAt: modifiedAt
                    )
                )
            }
        }
    }

    private nonisolated static func buildZipArchive(
        at archiveURL: URL,
        from rootURL: URL,
        fileManager: FileManager,
        onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> Int {
        let entries = try makeZipEntries(rootURL: rootURL, fileManager: fileManager)
        fileManager.createFile(atPath: archiveURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: archiveURL)
        defer { try? fileHandle.close() }

        var centralDirectory: [ZipCentralDirectoryRecord] = []
        var offset: UInt32 = 0

        for (index, entry) in entries.enumerated() {
            let pathData = Data(entry.path.utf8)
            let (crc, size): (UInt32, UInt32)
            if let fileURL = entry.fileURL {
                (crc, size) = try fileCRC32AndSize(at: fileURL)
            } else {
                (crc, size) = (0, 0)
            }

            let (dosTime, dosDate) = dosDateTime(for: entry.modifiedAt)
            let localHeaderOffset = offset

            var header = Data()
            appendUInt32LE(0x04034B50, to: &header)
            appendUInt16LE(20, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt16LE(dosTime, to: &header)
            appendUInt16LE(dosDate, to: &header)
            appendUInt32LE(crc, to: &header)
            appendUInt32LE(size, to: &header)
            appendUInt32LE(size, to: &header)
            appendUInt16LE(UInt16(pathData.count), to: &header)
            appendUInt16LE(0, to: &header)
            header.append(pathData)

            try write(header, to: fileHandle)
            offset += UInt32(header.count)

            if let fileURL = entry.fileURL {
                let written = try streamFile(at: fileURL, to: fileHandle)
                offset += UInt32(written)
            }

            centralDirectory.append(
                ZipCentralDirectoryRecord(
                    pathData: pathData,
                    crc32: crc,
                    size: size,
                    dosTime: dosTime,
                    dosDate: dosDate,
                    localHeaderOffset: localHeaderOffset
                )
            )
            onProgress(index + 1, entries.count)
        }

        let centralDirectoryOffset = offset
        for record in centralDirectory {
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
            appendUInt32LE(record.localHeaderOffset, to: &header)
            header.append(record.pathData)
            try write(header, to: fileHandle)
            offset += UInt32(header.count)
        }

        let centralDirectorySize = offset - centralDirectoryOffset
        let count = UInt16(min(centralDirectory.count, Int(UInt16.max)))
        var endOfCentralDirectory = Data()
        appendUInt32LE(0x06054B50, to: &endOfCentralDirectory)
        appendUInt16LE(0, to: &endOfCentralDirectory)
        appendUInt16LE(0, to: &endOfCentralDirectory)
        appendUInt16LE(count, to: &endOfCentralDirectory)
        appendUInt16LE(count, to: &endOfCentralDirectory)
        appendUInt32LE(centralDirectorySize, to: &endOfCentralDirectory)
        appendUInt32LE(centralDirectoryOffset, to: &endOfCentralDirectory)
        appendUInt16LE(0, to: &endOfCentralDirectory)
        try write(endOfCentralDirectory, to: fileHandle)

        return entries.count
    }

    private nonisolated static func fileCRC32AndSize(at url: URL) throws -> (UInt32, UInt32) {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        var crc: UInt32 = 0xFFFF_FFFF
        var size: UInt32 = 0
        while let chunk = try fileHandle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            size += UInt32(chunk.count)
            crc = updateCRC32(crc, with: chunk)
        }
        return (~crc, size)
    }

    private nonisolated static func streamFile(at url: URL, to fileHandle: FileHandle) throws -> Int {
        let inputHandle = try FileHandle(forReadingFrom: url)
        defer { try? inputHandle.close() }

        var totalWritten = 0
        while let chunk = try inputHandle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try write(chunk, to: fileHandle)
            totalWritten += chunk.count
        }
        return totalWritten
    }

    private nonisolated static func dosDateTime(for date: Date) -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, components.year ?? 1980)
        let month = max(1, min(12, components.month ?? 1))
        let day = max(1, min(31, components.day ?? 1))
        let hour = max(0, min(23, components.hour ?? 0))
        let minute = max(0, min(59, components.minute ?? 0))
        let second = max(0, min(59, components.second ?? 0))
        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }

    private nonisolated static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        crc = updateCRC32(crc, with: data)
        return ~crc
    }

    private nonisolated static func updateCRC32(_ crc: UInt32, with data: Data) -> UInt32 {
        var currentCRC = crc
        for byte in data {
            currentCRC ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(currentCRC & 1))
                currentCRC = (currentCRC >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return currentCRC
    }

    private nonisolated static func write(_ data: Data, to fileHandle: FileHandle) throws {
        try fileHandle.write(contentsOf: data)
    }

    private nonisolated static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private nonisolated static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

struct TemporaryMigrationImportView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var isShowingImporter: Bool = false
    @State private var selectedImportURL: URL? = nil
    @State private var showImportConfirm: Bool = false
    @State private var isImporting: Bool = false
    @State private var importPhaseMessage: String = "Idle"
    @State private var importStatusMessage: String? = nil
    @State private var importErrorMessage: String? = nil
    @State private var showImportError: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    importWarningCard

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Import Behavior")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)

                        importRow("Choose a `ScoutCapture_Migration.zip` file from Files, iCloud Drive, AirDrop, or Finder-transferred local storage")
                        importRow("Current local ScoutCapture migration-target data will be replaced")
                        importRow("Restores exported app files into the current ScoutCapture local storage root")
                        importRow("Restores only ScoutCapture-owned `UserDefaults` keys")
                        importRow("Supports offline recovery workflows when iCloud sync is unavailable")
                    }
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Button(action: { isShowingImporter = true }) {
                            HStack {
                                if isImporting {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.white)
                                }
                                Text(isImporting ? "Importing Migration Zip..." : "Choose Migration Zip")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundColor(.white)
                            .background(Color.green)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isImporting)

                        Text("Status: \(importPhaseMessage)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)

                        if let importStatusMessage {
                            Text(importStatusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.green)
                        }
                    }
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(16)
            }
            .navigationTitle("Archive Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                selectedImportURL = url
                showImportConfirm = true
            case let .failure(error):
                importErrorMessage = error.localizedDescription
                showImportError = true
            }
        }
        .alert("Import Migration Zip?", isPresented: $showImportConfirm) {
            Button("Import", role: .destructive) {
                beginImport()
            }
            Button("Cancel", role: .cancel) {
                selectedImportURL = nil
            }
        } message: {
            Text("This will replace current local ScoutCapture migration-target data in this app install with the selected migration zip.")
        }
        .alert("Migration Import Failed", isPresented: $showImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importErrorMessage ?? "Unable to import the migration zip.")
        }
    }

    private var importWarningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Internal Migration Use Only")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(importWarningLabelColor)

            Text("This temporary tool imports a one-time ScoutCapture migration archive into the current app install. It is intended for controlled migration testing only.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(importWarningLabelColor.opacity(0.9))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(importWarningFillColor)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var importWarningFillColor: Color {
        colorScheme == .light ? Color.green.opacity(0.16) : Color.green.opacity(0.22)
    }

    private var importWarningLabelColor: Color {
        colorScheme == .light ? Color.green.opacity(0.95) : Color.green.opacity(0.88)
    }

    private func importRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 2)

            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func beginImport() {
        guard !isImporting, let selectedImportURL else { return }
        isImporting = true
        importStatusMessage = nil
        importErrorMessage = nil
        showImportError = false
        importPhaseMessage = "Preparing import..."

        Task.detached(priority: .userInitiated) {
            do {
                let restoredSelectedPropertyID = try TemporaryMigrationImportManager.importMigrationArchive(
                    from: selectedImportURL
                ) { phase in
                    Task { @MainActor in
                        importPhaseMessage = phase
                    }
                }

                await MainActor.run {
                    isImporting = false
                    appState.completeMigrationImport(restoredSelectedPropertyID: restoredSelectedPropertyID)
                    importStatusMessage = "Migration import complete."
                    importPhaseMessage = "Import complete."
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importErrorMessage = error.localizedDescription
                    importPhaseMessage = "Import failed."
                    showImportError = true
                }
            }
        }
    }
}

enum TemporaryMigrationImportManager {
    private struct ZipEntry {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    private struct RestoredDefaultsPayload {
        let selectedPropertyID: UUID?
    }

    enum ImportError: LocalizedError {
        case unsupportedArchive
        case invalidArchiveStructure
        case unsupportedCompression(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedArchive:
                return "The selected file is not a supported ScoutCapture migration zip."
            case .invalidArchiveStructure:
                return "The migration zip structure is invalid."
            case let .unsupportedCompression(path):
                return "The migration zip contains an unsupported compressed entry: \(path)"
            }
        }
    }

    nonisolated static func importMigrationArchive(
        from archiveURL: URL,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        onPhaseUpdate: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> UUID? {
        onPhaseUpdate("Opening migration zip...")
        let didAccess = archiveURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                archiveURL.stopAccessingSecurityScopedResource()
            }
        }

        let zipFile = try FileHandle(forReadingFrom: archiveURL)
        defer {
            try? zipFile.close()
        }

        let entries = try loadEntries(from: zipFile)
        guard !entries.isEmpty else {
            throw ImportError.unsupportedArchive
        }

        let rootPrefix = "\(TemporaryMigrationExportConstants.exportRootFolderName)/"
        let applicationSupportPrefix = "\(rootPrefix)\(TemporaryMigrationExportConstants.applicationSupportFolderName)/"
        let documentsPrefix = "\(rootPrefix)\(TemporaryMigrationExportConstants.documentsFolderName)/"
        let userDefaultsPath = "\(rootPrefix)\(TemporaryMigrationExportConstants.userDefaultsFilename)"

        let applicationSupportRoot = StorageRoot.prepareStorage()
        let documentsRoot = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

        onPhaseUpdate("Clearing local ScoutCapture data...")
        try clearDirectoryContentsIfPresent(at: applicationSupportRoot, fileManager: fileManager)
        try fileManager.createDirectory(at: applicationSupportRoot, withIntermediateDirectories: true)
        try clearDirectoryContentsIfPresent(at: documentsRoot, fileManager: fileManager)
        try fileManager.createDirectory(at: documentsRoot, withIntermediateDirectories: true)
        clearScoutUserDefaults(userDefaults)

        var restoredDefaultsPayload = RestoredDefaultsPayload(selectedPropertyID: nil)
        var restoredFileCount = 0

        for entry in entries {
            guard entry.path.hasPrefix(rootPrefix) else { continue }

            if entry.path == userDefaultsPath {
                onPhaseUpdate("Restoring ScoutCapture preferences...")
                let data = try extractData(for: entry, from: zipFile)
                restoredDefaultsPayload = try restoreUserDefaults(from: data, userDefaults: userDefaults)
                continue
            }

            if entry.path.hasSuffix("/") {
                continue
            }

            let destinationURL: URL?
            if entry.path.hasPrefix(applicationSupportPrefix) {
                let relativePath = String(entry.path.dropFirst(applicationSupportPrefix.count))
                destinationURL = applicationSupportRoot.appendingPathComponent(relativePath, isDirectory: false)
                onPhaseUpdate("Restoring Application Support files...")
            } else if entry.path.hasPrefix(documentsPrefix) {
                let relativePath = String(entry.path.dropFirst(documentsPrefix.count))
                destinationURL = documentsRoot.appendingPathComponent(relativePath, isDirectory: false)
                onPhaseUpdate("Restoring Documents files...")
            } else {
                destinationURL = nil
            }

            guard let destinationURL else { continue }
            try extractEntry(entry, from: zipFile, to: destinationURL, fileManager: fileManager)
            restoredFileCount += 1
        }

        onPhaseUpdate("Imported \(restoredFileCount) files.")
        return restoredDefaultsPayload.selectedPropertyID
    }

    private nonisolated static func clearDirectoryContentsIfPresent(
        at url: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for child in children {
            try fileManager.removeItem(at: child)
        }
    }

    private nonisolated static func clearScoutUserDefaults(_ userDefaults: UserDefaults) {
        for key in userDefaults.dictionaryRepresentation().keys where shouldRestoreUserDefaultsKey(key) {
            userDefaults.removeObject(forKey: key)
        }
        userDefaults.synchronize()
    }

    private nonisolated static func restoreUserDefaults(
        from data: Data,
        userDefaults: UserDefaults
    ) throws -> RestoredDefaultsPayload {
        guard let rootObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = rootObject["values"] as? [String: Any] else {
            throw ImportError.invalidArchiveStructure
        }

        for (key, value) in values where shouldRestoreUserDefaultsKey(key) {
            userDefaults.set(decodedUserDefaultsValue(value), forKey: key)
        }
        userDefaults.synchronize()

        let selectedPropertyID = (values["scoutcapture.selectedPropertyID"] as? String).flatMap(UUID.init(uuidString:))
        return RestoredDefaultsPayload(selectedPropertyID: selectedPropertyID)
    }

    private nonisolated static func shouldRestoreUserDefaultsKey(_ key: String) -> Bool {
        key.hasPrefix("scout.") ||
        key.hasPrefix("scoutcapture.") ||
        key.hasPrefix("scout.captureProfile.property.")
    }

    private nonisolated static func decodedUserDefaultsValue(_ value: Any) -> Any? {
        if let dictionary = value as? [String: Any],
           let type = dictionary["type"] as? String,
           type == "data",
           let base64 = dictionary["base64"] as? String,
           let data = Data(base64Encoded: base64) {
            return data
        }

        if let array = value as? [Any] {
            return array.compactMap { decodedUserDefaultsValue($0) }
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { decodedUserDefaultsValue($0) as Any }
        }

        return value
    }

    private nonisolated static func loadEntries(from file: FileHandle) throws -> [ZipEntry] {
        let fileSize = try file.seekToEnd()
        let tailLength = Int(min(UInt64(66_000), fileSize))
        try file.seek(toOffset: fileSize - UInt64(tailLength))
        guard let tailData = try file.read(upToCount: tailLength) else {
            throw ImportError.unsupportedArchive
        }

        let eocdSignature = Data([0x50, 0x4B, 0x05, 0x06])
        guard let eocdRange = tailData.range(of: eocdSignature, options: .backwards) else {
            throw ImportError.unsupportedArchive
        }

        let eocdOffset = eocdRange.lowerBound
        let centralDirectorySize: UInt32 = readLittleEndian(at: eocdOffset + 12, in: tailData)
        let centralDirectoryOffset: UInt32 = readLittleEndian(at: eocdOffset + 16, in: tailData)
        let totalEntryCount = Int(readLittleEndian(at: eocdOffset + 10, in: tailData) as UInt16)

        try file.seek(toOffset: UInt64(centralDirectoryOffset))
        guard let centralDirectoryData = try file.read(upToCount: Int(centralDirectorySize)) else {
            throw ImportError.invalidArchiveStructure
        }

        var cursor = 0
        var entries: [ZipEntry] = []

        while cursor + 46 <= centralDirectoryData.count, entries.count < totalEntryCount {
            let signature: UInt32 = readLittleEndian(at: cursor, in: centralDirectoryData)
            guard signature == 0x02014B50 else {
                throw ImportError.invalidArchiveStructure
            }

            let compressionMethod: UInt16 = readLittleEndian(at: cursor + 10, in: centralDirectoryData)
            let compressedSize: UInt32 = readLittleEndian(at: cursor + 20, in: centralDirectoryData)
            let uncompressedSize: UInt32 = readLittleEndian(at: cursor + 24, in: centralDirectoryData)
            let fileNameLength = Int(readLittleEndian(at: cursor + 28, in: centralDirectoryData) as UInt16)
            let extraFieldLength = Int(readLittleEndian(at: cursor + 30, in: centralDirectoryData) as UInt16)
            let commentLength = Int(readLittleEndian(at: cursor + 32, in: centralDirectoryData) as UInt16)
            let localHeaderOffset: UInt32 = readLittleEndian(at: cursor + 42, in: centralDirectoryData)

            let nameStart = cursor + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= centralDirectoryData.count else {
                throw ImportError.invalidArchiveStructure
            }

            let path = String(decoding: centralDirectoryData[nameStart..<nameEnd], as: UTF8.self)
            entries.append(
                ZipEntry(
                    path: path,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
            )

            cursor = nameEnd + extraFieldLength + commentLength
        }

        return entries
    }

    private nonisolated static func extractEntry(
        _ entry: ZipEntry,
        from file: FileHandle,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let data = try extractData(for: entry, from: file)
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try data.write(to: destinationURL, options: [.atomic])
    }

    private nonisolated static func extractData(
        for entry: ZipEntry,
        from file: FileHandle
    ) throws -> Data {
        guard entry.compressionMethod == 0 else {
            throw ImportError.unsupportedCompression(entry.path)
        }

        try file.seek(toOffset: UInt64(entry.localHeaderOffset))
        guard let localHeader = try file.read(upToCount: 30), localHeader.count == 30 else {
            throw ImportError.invalidArchiveStructure
        }

        let signature: UInt32 = readLittleEndian(at: 0, in: localHeader)
        guard signature == 0x04034B50 else {
            throw ImportError.invalidArchiveStructure
        }

        let fileNameLength = UInt64(readLittleEndian(at: 26, in: localHeader) as UInt16)
        let extraFieldLength = UInt64(readLittleEndian(at: 28, in: localHeader) as UInt16)
        let dataOffset = UInt64(entry.localHeaderOffset) + 30 + fileNameLength + extraFieldLength

        try file.seek(toOffset: dataOffset)
        guard let data = try file.read(upToCount: Int(entry.compressedSize)),
              data.count == Int(entry.compressedSize),
              UInt32(data.count) == entry.uncompressedSize else {
            throw ImportError.invalidArchiveStructure
        }

        return data
    }
}

private nonisolated func readLittleEndian<T: FixedWidthInteger, D: DataProtocol>(at offset: Int, in data: D) -> T {
    let size = MemoryLayout<T>.size
    let start = data.index(data.startIndex, offsetBy: offset)
    let end = data.index(start, offsetBy: size)
    let slice = data[start..<end]
    var value: T = 0
    withUnsafeMutableBytes(of: &value) { destination in
        destination.copyBytes(from: slice)
    }
    return T(littleEndian: value)
}
