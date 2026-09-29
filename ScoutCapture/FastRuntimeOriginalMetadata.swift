import CoreLocation
import CryptoKit
import Darwin
import Foundation
import ImageIO

// A serial queue orders background annotation ahead of any upload preflight. The JPEG itself
// is the durable completion marker, so an interrupted annotation can resume after relaunch.
enum FastRuntimeOriginalMetadata {
    private static let queue = DispatchQueue(label: "scoutcapture.fast-original-metadata", qos: .utility)

    struct UploadFingerprint: Equatable {
        let checksumSHA256: String
        let byteSize: Int
    }

    static func uploadFingerprint(at fileURL: URL) throws -> UploadFingerprint {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        return UploadFingerprint(
            checksumSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteSize: data.count
        )
    }

    static func schedule(_ shot: AppState.FastRuntimePrototypeShotRecord) {
        queue.async {
            do {
                try annotateIfNeeded(shot)
            } catch {
                // Keep the raw original. Upload preflight retries and reports this failure.
                print("[FastOriginalMetadata] shot=\(shot.id.uuidString) annotation_failed=\(error.localizedDescription)")
            }
        }
    }

    static func scheduleDurableCopy(
        _ shot: AppState.FastRuntimePrototypeShotRecord,
        to durableURL: URL
    ) {
        queue.async {
            do {
                try annotateIfNeeded(shot)
                try synchronizeDurableCopy(shot, to: durableURL)
            } catch {
                print("[FastOriginalMetadata] shot=\(shot.id.uuidString) durable_copy_failed=\(error.localizedDescription)")
            }
        }
    }

    static func prepareForUpload(
        _ shots: [AppState.FastRuntimePrototypeShotRecord],
        durableURLsByShotID: [UUID: URL] = [:],
        authorizationStatus: CLAuthorizationStatus? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    for shot in shots {
                        try annotateIfNeeded(shot, authorizationStatus: authorizationStatus)
                        if let durableURL = durableURLsByShotID[shot.id] {
                            try synchronizeDurableCopy(shot, to: durableURL)
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func synchronizeDurableCopy(
        _ shot: AppState.FastRuntimePrototypeShotRecord,
        to durableURL: URL
    ) throws {
        let originalURL = URL(fileURLWithPath: shot.localFilePath)
        guard durableURL.standardizedFileURL.path != originalURL.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: durableURL.path) else { return }
        let finishedData = try Data(contentsOf: originalURL, options: [.mappedIfSafe])
        guard containsScoutShotID(finishedData, shotID: shot.id) else {
            throw NSError(domain: "ScoutCapture.FastOriginalMetadata", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "The finished photo metadata is missing."
            ])
        }
        try finishedData.write(to: durableURL, options: .atomic)
    }

    // Internal for focused tests. The production caller reads authorization immediately before
    // writing, while coordinates are always the fix saved at the original shutter press.
    static func annotateIfNeeded(
        _ shot: AppState.FastRuntimePrototypeShotRecord,
        authorizationStatus: CLAuthorizationStatus? = nil
    ) throws {
        let originalURL = URL(fileURLWithPath: shot.localFilePath, isDirectory: false)
        let sourceData = try Data(contentsOf: originalURL, options: [.mappedIfSafe])
        if containsScoutShotID(sourceData, shotID: shot.id) { return }

        let stored = shot.metadataContext
        let status = authorizationStatus ?? CLLocationManager.authorizationStatus()
        let permitsGPS = status == .authorizedWhenInUse || status == .authorizedAlways
        let latitude = permitsGPS ? stored?.latitude : nil
        let longitude = permitsGPS ? stored?.longitude : nil
        let accuracy = permitsGPS ? stored?.accuracyMeters : nil
        let metadata = ReportLibraryModel.EmbeddedMetadataContext(
            propertyID: shot.propertyID,
            propertyName: stored?.propertyName,
            propertyAddress: stored?.propertyAddress,
            sessionID: shot.sessionID,
            shotID: shot.id,
            shotKey: stored?.shotKey,
            building: stored?.building,
            elevation: stored?.elevation,
            detailType: stored?.detailType,
            angleIndex: stored?.angleIndex,
            trade: stored?.trade,
            priority: stored?.priority,
            isGuided: stored?.isGuided,
            isFlagged: stored?.isFlagged,
            issueStatus: stored?.issueStatus,
            detailNote: stored?.detailNote,
            captureMode: stored?.captureMode,
            lens: stored?.lens,
            orientation: sourceOrientationDescription(sourceData),
            capturedExifOrientationRaw: nil,
            latitude: latitude,
            longitude: longitude,
            accuracyMeters: accuracy,
            appVersion: stored?.appVersion,
            osVersion: stored?.osVersion,
            deviceModel: stored?.deviceModel,
            schemaVersion: 4
        )
        let annotatedData = try ReportLibraryModel().annotatedFastOriginalJPEGData(
            from: sourceData,
            captureDate: shot.capturedAt,
            metadataContext: metadata
        )
        guard containsScoutShotID(annotatedData, shotID: shot.id),
              hasGPS(annotatedData) == (latitude != nil && longitude != nil) else {
            throw NSError(domain: "ScoutCapture.FastOriginalMetadata", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The JPG metadata could not be verified. The original photo was kept."
            ])
        }

        let temporaryURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(shot.id.uuidString).metadata-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try annotatedData.write(to: temporaryURL, options: .atomic)
        guard rename(temporaryURL.path, originalURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "The annotated JPG could not replace the original. The original photo was kept."
            ])
        }
    }

    static func containsScoutShotID(_ data: Data, shotID: UUID) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let comment = exif[kCGImagePropertyExifUserComment] as? String else { return false }
        return comment.split(separator: ";").contains { String($0) == "shotID=\(shotID.uuidString)" }
    }

    static func hasGPS(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] else { return false }
        return gps[kCGImagePropertyGPSLatitude] != nil && gps[kCGImagePropertyGPSLongitude] != nil
    }

    static func embeddedGPS(at fileURL: URL?) -> (latitude: Double, longitude: Double, accuracyMeters: Double?)? {
        guard let fileURL,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = numericGPSValue(gps[kCGImagePropertyGPSLatitude]),
              let longitude = numericGPSValue(gps[kCGImagePropertyGPSLongitude]) else { return nil }
        let latitudeSign = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -1.0 : 1.0
        let longitudeSign = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -1.0 : 1.0
        let xmpAccuracy = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
            .flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "scout:gpsAccuracyMeters" as CFString) }
            .flatMap { Double($0 as String) }
        return (
            latitude: latitude * latitudeSign,
            longitude: longitude * longitudeSign,
            accuracyMeters: xmpAccuracy ?? numericGPSValue(gps[kCGImagePropertyGPSHPositioningError])
        )
    }

    private static func numericGPSValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func sourceOrientationDescription(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? NSNumber else { return nil }
        return "exif:\(orientation.uint32Value)"
    }
}
