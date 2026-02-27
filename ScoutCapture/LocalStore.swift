import Foundation
import UIKit

final class LocalStore {
    private let currentSessionSchemaVersion = 4
    private let fileIOQueue = DispatchQueue(label: "ScoutCapture.LocalStore.fileIO")
    private let fileIOQueueKey = DispatchSpecificKey<UInt8>()
    private let fileIOQueueValue: UInt8 = 1

    enum ShotUpsertMatchMode {
        case append
        case replaceGuidedKey
    }

    enum StoreError: Error {
        case propertyNotFound(UUID)
        case observationNotFound(UUID)
        case sessionNotFound(UUID)
    }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let scoutRootURL: URL
    private let propertiesURL: URL
    private let propertyFoldersURL: URL
    private let observationsDirectoryURL: URL
    private let guidedShotsDirectoryURL: URL
    private let sessionsDirectoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appRoot = appSupport.appendingPathComponent("ScoutCapture", isDirectory: true)
        let scoutRoot = appRoot.appendingPathComponent("SCOUT", isDirectory: true)
        self.scoutRootURL = scoutRoot
        self.propertiesURL = scoutRoot.appendingPathComponent("properties.json")
        self.propertyFoldersURL = scoutRoot.appendingPathComponent("Properties", isDirectory: true)
        self.observationsDirectoryURL = scoutRoot.appendingPathComponent("observations", isDirectory: true)
        self.guidedShotsDirectoryURL = scoutRoot.appendingPathComponent("guided-shots", isDirectory: true)
        self.sessionsDirectoryURL = scoutRoot.appendingPathComponent("sessions", isDirectory: true)
        self.fileIOQueue.setSpecific(key: fileIOQueueKey, value: fileIOQueueValue)

        try? createStorageDirectories(baseDirectoryURL: scoutRoot)
    }

    func performFileIOSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: fileIOQueueKey) == fileIOQueueValue {
            return try work()
        }
        return try fileIOQueue.sync {
            try work()
        }
    }

    // MARK: - Properties CRUD

    func fetchProperties() throws -> [Property] {
        try readProperties()
    }

    @discardableResult
    func createProperty(_ property: Property) throws -> Property {
        var properties = try readProperties()
        properties.append(property)
        try writeProperties(properties)
        return property
    }

    @discardableResult
    func updateProperty(_ property: Property) throws -> Property {
        var properties = try readProperties()
        guard let index = properties.firstIndex(where: { $0.id == property.id }) else {
            throw StoreError.propertyNotFound(property.id)
        }

        var updated = property
        updated.updatedAt = Date()
        properties[index] = updated
        try writeProperties(properties)
        return updated
    }

    func deleteProperty(id: UUID) throws {
        try performFileIOSync {
            let guided = try readGuidedShots(propertyID: id)
            let observations = try readObservations(propertyID: id)
            try cleanupReferenceFilesForGuidedShots(guided)
            let observationGuidedRefs = observations.flatMap { $0.guidedShots.compactMap(\.referenceImagePath) }
            try cleanupReferenceFiles(paths: observationGuidedRefs)

            var properties = try readProperties()
            properties.removeAll { $0.id == id }
            try writeProperties(properties)

            let propertyObservationURL = observationsFileURL(for: id)
            if fileManager.fileExists(atPath: propertyObservationURL.path) {
                try fileManager.removeItem(at: propertyObservationURL)
            }

            let propertyGuidedShotsURL = guidedShotsFileURL(for: id)
            if fileManager.fileExists(atPath: propertyGuidedShotsURL.path) {
                try fileManager.removeItem(at: propertyGuidedShotsURL)
            }

            let propertySessionsURL = sessionsFileURL(for: id)
            if fileManager.fileExists(atPath: propertySessionsURL.path) {
                try fileManager.removeItem(at: propertySessionsURL)
            }

            let propertyFolder = propertyFolderURL(propertyID: id)
            if fileManager.fileExists(atPath: propertyFolder.path) {
                try? fileManager.removeItem(at: propertyFolder)
            }
        }
    }

    // MARK: - Observations CRUD (per-property)

    func fetchObservations(propertyID: UUID) throws -> [Observation] {
        try ensurePropertyExists(propertyID)
        let observations = try readObservations(propertyID: propertyID)
        if try hasLegacyElevationValues(in: observationsFileURL(for: propertyID)) {
            try writeObservations(observations, propertyID: propertyID)
        }
        return observations
    }

    @discardableResult
    func createObservation(_ observation: Observation) throws -> Observation {
        try ensurePropertyExists(observation.propertyID)
        var observations = try readObservations(propertyID: observation.propertyID)
        observations.append(observation)
        try writeObservations(observations, propertyID: observation.propertyID)
        return observation
    }

    @discardableResult
    func updateObservation(_ observation: Observation) throws -> Observation {
        try ensurePropertyExists(observation.propertyID)
        var observations = try readObservations(propertyID: observation.propertyID)
        guard let index = observations.firstIndex(where: { $0.id == observation.id }) else {
            throw StoreError.observationNotFound(observation.id)
        }

        var updated = observation
        updated.updatedAt = Date()
        observations[index] = updated
        try writeObservations(observations, propertyID: observation.propertyID)
        return updated
    }

    func deleteObservation(id: UUID, propertyID: UUID) throws {
        try ensurePropertyExists(propertyID)
        var observations = try readObservations(propertyID: propertyID)
        observations.removeAll { $0.id == id }
        try writeObservations(observations, propertyID: propertyID)
    }

    // MARK: - Guided Shots CRUD (per-property)

    func fetchGuidedShots(propertyID: UUID) throws -> [GuidedShot] {
        try ensurePropertyExists(propertyID)
        let guidedShots = try readGuidedShots(propertyID: propertyID)
        if try hasLegacyElevationValues(in: guidedShotsFileURL(for: propertyID)) {
            try writeGuidedShots(guidedShots, propertyID: propertyID)
        }
        return guidedShots
    }

    func saveGuidedShots(_ guidedShots: [GuidedShot], propertyID: UUID) throws {
        try ensurePropertyExists(propertyID)
        try writeGuidedShots(guidedShots, propertyID: propertyID)
    }
    
    // MARK: - Sessions CRUD (per-property)
    
    func fetchSessions(propertyID: UUID) throws -> [Session] {
        try ensurePropertyExists(propertyID)
        return try readSessions(propertyID: propertyID)
    }
    
    @discardableResult
    func upsertSession(_ session: Session) throws -> Session {
        try ensurePropertyExists(session.propertyID)
        var sessions = try readSessions(propertyID: session.propertyID)
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        sessions.sort { $0.startedAt < $1.startedAt }
        try writeSessions(sessions, propertyID: session.propertyID)
        try upsertSessionMetadataLifecycle(for: session)
        return session
    }

    func ensureSessionMetadata(for session: Session) throws {
        try upsertSessionMetadataLifecycle(for: session)
    }

    func upsertShotMetadata(_ shot: ShotMetadata) throws {
        try upsertShot(
            propertyID: shot.propertyID,
            sessionID: shot.sessionID,
            shot: shot,
            matchMode: .replaceGuidedKey
        )
    }

    func loadSessionMetadata(propertyID: UUID, sessionID: UUID) throws -> SessionMetadata {
        try readOrRecoverSessionMetadata(propertyID: propertyID, sessionID: sessionID)
    }

    func saveSessionMetadataAtomically(propertyID: UUID, sessionID: UUID, metadata: SessionMetadata) throws {
        var updated = metadata
        updated.schemaVersion = max(updated.schemaVersion, currentSessionSchemaVersion)
        updated.propertyID = propertyID
        updated.sessionID = sessionID
        updated.appVersion = appVersionString()
        updated.deviceModel = deviceModelString()
        updated.osVersion = osVersionString()
        try writeSessionMetadata(updated)
    }

    func upsertShot(
        propertyID: UUID,
        sessionID: UUID,
        shot: ShotMetadata,
        matchMode: ShotUpsertMatchMode
    ) throws {
        var metadata = try loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        metadata.schemaVersion = max(metadata.schemaVersion, currentSessionSchemaVersion)
        metadata.propertyID = propertyID
        metadata.sessionID = sessionID

        if let index = metadata.shots.firstIndex(where: { $0.shotID == shot.shotID }) {
            let existing = metadata.shots[index]
            var replacement = shot
            replacement = ShotMetadata(
                shotID: existing.shotID,
                propertyID: shot.propertyID,
                sessionID: shot.sessionID,
                createdAt: existing.createdAt,
                updatedAt: shot.updatedAt,
                building: shot.building,
                elevation: shot.elevation,
                detailType: shot.detailType,
                angleIndex: shot.angleIndex,
                shotKey: shot.shotKey,
                isGuided: shot.isGuided,
                isFlagged: shot.isFlagged,
                issueID: shot.issueID,
                issueStatus: shot.issueStatus,
                noteText: shot.noteText,
                noteCategory: shot.noteCategory,
                originalFilename: shot.originalFilename,
                originalRelativePath: shot.originalRelativePath,
                originalByteSize: shot.originalByteSize,
                stampedFilename: shot.stampedFilename,
                stampedRelativePath: shot.stampedRelativePath,
                captureMode: shot.captureMode,
                lens: shot.lens,
                orientation: shot.orientation,
                latitude: shot.latitude,
                longitude: shot.longitude,
                accuracyMeters: shot.accuracyMeters,
                imageWidth: shot.imageWidth,
                imageHeight: shot.imageHeight
            )
            metadata.shots[index] = replacement
        } else if matchMode == .replaceGuidedKey,
                  shot.isGuided,
                  let index = metadata.shots.firstIndex(where: {
                      $0.isGuided &&
                      $0.propertyID == shot.propertyID &&
                      $0.sessionID == shot.sessionID &&
                      (
                        $0.shotKey.caseInsensitiveCompare(shot.shotKey) == .orderedSame ||
                        (
                            $0.building.caseInsensitiveCompare(shot.building) == .orderedSame &&
                            CanonicalElevation.normalize($0.elevation) == CanonicalElevation.normalize(shot.elevation) &&
                            $0.detailType.caseInsensitiveCompare(shot.detailType) == .orderedSame &&
                            $0.angleIndex == shot.angleIndex
                        )
                      )
                  }) {
            let existing = metadata.shots[index]
            let replacement = ShotMetadata(
                shotID: existing.shotID,
                propertyID: shot.propertyID,
                sessionID: shot.sessionID,
                createdAt: existing.createdAt,
                updatedAt: shot.updatedAt,
                building: shot.building,
                elevation: shot.elevation,
                detailType: shot.detailType,
                angleIndex: shot.angleIndex,
                shotKey: shot.shotKey,
                isGuided: shot.isGuided,
                isFlagged: shot.isFlagged,
                issueID: shot.issueID,
                issueStatus: shot.issueStatus,
                noteText: shot.noteText,
                noteCategory: shot.noteCategory,
                originalFilename: shot.originalFilename,
                originalRelativePath: shot.originalRelativePath,
                originalByteSize: shot.originalByteSize,
                stampedFilename: shot.stampedFilename,
                stampedRelativePath: shot.stampedRelativePath,
                captureMode: shot.captureMode,
                lens: shot.lens,
                orientation: shot.orientation,
                latitude: shot.latitude,
                longitude: shot.longitude,
                accuracyMeters: shot.accuracyMeters,
                imageWidth: shot.imageWidth,
                imageHeight: shot.imageHeight
            )
            metadata.shots[index] = replacement
        } else {
            if matchMode == .replaceGuidedKey {
                print("Retake upsert fallback append: guided key match not found for session \(sessionID)")
            }
            metadata.shots.append(shot)
        }

        try saveSessionMetadataAtomically(propertyID: propertyID, sessionID: sessionID, metadata: metadata)
    }

    func removeShotMetadata(
        propertyID: UUID,
        sessionID: UUID,
        originalFileIdentifiers: [String]
    ) throws {
        try performFileIOSync {
            guard !originalFileIdentifiers.isEmpty else { return }
            var metadata = try readOrRecoverSessionMetadata(propertyID: propertyID, sessionID: sessionID)
            let targets = Set(originalFileIdentifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            guard !targets.isEmpty else { return }
            metadata.shots.removeAll { shot in
                let original = shot.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
                let stem = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
                return targets.contains(original)
                    || targets.contains(stem)
                    || targets.contains("/\(stem).jpg")
                    || targets.contains("/\(stem).heic")
            }
            try writeSessionMetadata(metadata)
        }
    }

    func fetchShotMetadata(propertyID: UUID, sessionID: UUID) throws -> [ShotMetadata] {
        let metadata = try readOrRecoverSessionMetadata(propertyID: propertyID, sessionID: sessionID)
        return metadata.shots
    }
    
    func latestDraftSession(propertyID: UUID) throws -> Session? {
        let sessions = try fetchSessions(propertyID: propertyID)
        return sessions
            .filter { $0.status == .draft }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }

    func deleteSession(id: UUID, propertyID: UUID) throws {
        try performFileIOSync {
            try ensurePropertyExists(propertyID)
            var sessions = try readSessions(propertyID: propertyID)
            sessions.removeAll { $0.id == id }
            try writeSessions(sessions, propertyID: propertyID)
            let metadataFolder = sessionMetadataFolderURL(propertyID: propertyID, sessionID: id)
            if fileManager.fileExists(atPath: metadataFolder.path) {
                try? fileManager.removeItem(at: metadataFolder)
            }
        }
    }

    func deleteSessionCascade(id: UUID, propertyID: UUID) throws {
        try performFileIOSync {
            try ensurePropertyExists(propertyID)
            let sessions = try readSessions(propertyID: propertyID)
            guard let target = sessions.first(where: { $0.id == id }) else {
                throw StoreError.sessionNotFound(id)
            }

            let start = target.startedAt
            let end = target.endedAt ?? Date.distantFuture

            var observations = try readObservations(propertyID: propertyID)
            let sessionMatched = observations.filter { $0.sessionID == target.id }
            let timeMatched = observations.filter { $0.sessionID == nil && $0.createdAt >= start && $0.createdAt <= end }
            let matchedObservationIDs = Set((sessionMatched + timeMatched).map(\.id))
            let matchedObservations = observations.filter { matchedObservationIDs.contains($0.id) }
            let matchedShotIDs = Set(matchedObservations.flatMap { obs in
                var ids = obs.shots.map(\.id)
                if let linked = obs.linkedShotID {
                    ids.append(linked)
                }
                return ids
            })

            let observationGuidedRefs = matchedObservations.flatMap { $0.guidedShots.compactMap(\.referenceImagePath) }
            try cleanupReferenceFiles(paths: observationGuidedRefs)
            observations.removeAll { matchedObservationIDs.contains($0.id) }
            try writeObservations(observations, propertyID: propertyID)

            var guided = try readGuidedShots(propertyID: propertyID)
            let guidedToDelete = guided.filter { shot in
                if let shotID = shot.shot?.id, matchedShotIDs.contains(shotID) {
                    return true
                }
                if let capturedAt = shot.shot?.capturedAt, capturedAt >= start && capturedAt <= end {
                    return true
                }
                return false
            }
            try cleanupReferenceFilesForGuidedShots(guidedToDelete)
            guided.removeAll { item in guidedToDelete.contains(where: { $0.id == item.id }) }
            try writeGuidedShots(guided, propertyID: propertyID)

            var updatedSessions = sessions
            updatedSessions.removeAll { $0.id == id }
            try writeSessions(updatedSessions, propertyID: propertyID)
            let metadataFolder = sessionMetadataFolderURL(propertyID: propertyID, sessionID: id)
            if fileManager.fileExists(atPath: metadataFolder.path) {
                try? fileManager.removeItem(at: metadataFolder)
            }
        }
    }

    func ensureSessionFolders(propertyID: UUID, sessionID: UUID) throws {
        let propertyFolder = propertyFolderURL(propertyID: propertyID)
        if !fileManager.fileExists(atPath: propertyFolder.path) {
            try fileManager.createDirectory(at: propertyFolder, withIntermediateDirectories: true)
        }

        let sessionsFolder = sessionsFolderURL(propertyID: propertyID)
        if !fileManager.fileExists(atPath: sessionsFolder.path) {
            try fileManager.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
        }

        let sessionFolder = sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: sessionFolder.path) {
            try fileManager.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        }

        let originals = originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: originals.path) {
            try fileManager.createDirectory(at: originals, withIntermediateDirectories: true)
        }

        let stamped = stampedFolderURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: stamped.path) {
            try fileManager.createDirectory(at: stamped, withIntermediateDirectories: true)
        }
    }

    func ensureSessionFileStorage(propertyID: UUID, sessionID: UUID) throws {
        try ensureSessionFolders(propertyID: propertyID, sessionID: sessionID)
    }

    func rootURL() -> URL {
        scoutRootURL
    }

    func propertyFolderURL(propertyID: UUID) -> URL {
        propertyFoldersURL.appendingPathComponent(propertyID.uuidString, isDirectory: true)
    }

    func sessionsFolderURL(propertyID: UUID) -> URL {
        propertyFolderURL(propertyID: propertyID)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    func sessionFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionsFolderURL(propertyID: propertyID)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func originalsFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent("Originals", isDirectory: true)
    }

    func stampedFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent("Stamped", isDirectory: true)
    }

    func sessionJSONURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent("session.json")
    }

    // Backward-compatible wrappers used by existing call sites.
    func originalsDirectoryURL(propertyID: UUID, sessionID: UUID) -> URL {
        originalsFolderURL(propertyID: propertyID, sessionID: sessionID)
    }

    func stampedDirectoryURL(propertyID: UUID, sessionID: UUID) -> URL {
        stampedFolderURL(propertyID: propertyID, sessionID: sessionID)
    }

    func wipeAllLocalData() throws {
        try performFileIOSync {
            if fileManager.fileExists(atPath: scoutRootURL.path) {
                try fileManager.removeItem(at: scoutRootURL)
            }
            try createStorageDirectories(baseDirectoryURL: scoutRootURL)
        }
    }

    // MARK: - Private Helpers

    private func createStorageDirectories(baseDirectoryURL: URL) throws {
        if !fileManager.fileExists(atPath: baseDirectoryURL.path) {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: observationsDirectoryURL.path) {
            try fileManager.createDirectory(at: observationsDirectoryURL, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: guidedShotsDirectoryURL.path) {
            try fileManager.createDirectory(at: guidedShotsDirectoryURL, withIntermediateDirectories: true)
        }
        
        if !fileManager.fileExists(atPath: sessionsDirectoryURL.path) {
            try fileManager.createDirectory(at: sessionsDirectoryURL, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: propertyFoldersURL.path) {
            try fileManager.createDirectory(at: propertyFoldersURL, withIntermediateDirectories: true)
        }
    }

    private func ensurePropertyExists(_ propertyID: UUID) throws {
        let properties = try readProperties()
        guard properties.contains(where: { $0.id == propertyID }) else {
            throw StoreError.propertyNotFound(propertyID)
        }
    }

    private func readProperties() throws -> [Property] {
        guard fileManager.fileExists(atPath: propertiesURL.path) else {
            return []
        }

        let data = try Data(contentsOf: propertiesURL)
        return try decoder.decode([Property].self, from: data)
    }

    private func writeProperties(_ properties: [Property]) throws {
        let data = try encoder.encode(properties)
        try data.write(to: propertiesURL, options: .atomic)
    }

    private func observationsFileURL(for propertyID: UUID) -> URL {
        observationsDirectoryURL.appendingPathComponent("\(propertyID.uuidString).json")
    }

    private func guidedShotsFileURL(for propertyID: UUID) -> URL {
        guidedShotsDirectoryURL.appendingPathComponent("\(propertyID.uuidString).json")
    }
    
    private func sessionsFileURL(for propertyID: UUID) -> URL {
        sessionsDirectoryURL.appendingPathComponent("\(propertyID.uuidString).json")
    }

    private func readObservations(propertyID: UUID) throws -> [Observation] {
        let fileURL = observationsFileURL(for: propertyID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([Observation].self, from: data)
    }

    private func writeObservations(_ observations: [Observation], propertyID: UUID) throws {
        let data = try encoder.encode(observations)
        let fileURL = observationsFileURL(for: propertyID)
        try data.write(to: fileURL, options: .atomic)
    }

    private func readGuidedShots(propertyID: UUID) throws -> [GuidedShot] {
        let fileURL = guidedShotsFileURL(for: propertyID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([GuidedShot].self, from: data)
    }

    private func writeGuidedShots(_ guidedShots: [GuidedShot], propertyID: UUID) throws {
        let data = try encoder.encode(guidedShots)
        let fileURL = guidedShotsFileURL(for: propertyID)
        try data.write(to: fileURL, options: .atomic)
    }
    
    private func readSessions(propertyID: UUID) throws -> [Session] {
        let fileURL = sessionsFileURL(for: propertyID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([Session].self, from: data)
    }
    
    private func writeSessions(_ sessions: [Session], propertyID: UUID) throws {
        let data = try encoder.encode(sessions)
        let fileURL = sessionsFileURL(for: propertyID)
        try data.write(to: fileURL, options: .atomic)
    }

    private func cleanupReferenceFilesForGuidedShots(_ guidedShots: [GuidedShot]) throws {
        let paths = guidedShots.compactMap(\.referenceImagePath)
        try cleanupReferenceFiles(paths: paths)
    }

    private func cleanupReferenceFiles(paths: [String]) throws {
        let unique = Set(paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        for path in unique {
            if fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
            }
        }
    }

    private func upsertSessionMetadataLifecycle(for session: Session) throws {
        var metadata = try readOrRecoverSessionMetadata(propertyID: session.propertyID, sessionID: session.id)
        metadata.schemaVersion = max(metadata.schemaVersion, currentSessionSchemaVersion)
        metadata.propertyID = session.propertyID
        metadata.sessionID = session.id
        let propertyName = currentPropertyName(for: session.propertyID)
        if (metadata.propertyNameAtCapture ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !propertyName.isEmpty {
            metadata.propertyNameAtCapture = propertyName
        }
        if session.exportedAt != nil, !propertyName.isEmpty {
            metadata.propertyNameAtExport = propertyName
        }
        metadata.startedAt = session.startedAt
        metadata.endedAt = session.endedAt
        metadata.status = session.status
        metadata.isBaselineSession = isBaselineSession(sessionID: session.id, propertyID: session.propertyID)
        metadata.exportedAt = session.exportedAt
        metadata.isSealed = session.isSealed
        metadata.firstDeliveredAt = session.firstDeliveredAt
        metadata.reExportExpiresAt = session.reExportExpiresAt
        metadata.appVersion = appVersionString()
        metadata.deviceModel = deviceModelString()
        metadata.osVersion = osVersionString()
        try writeSessionMetadata(metadata)
    }

    private func readOrRecoverSessionMetadata(propertyID: UUID, sessionID: UUID) throws -> SessionMetadata {
        let fileURL = sessionMetadataFileURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: fileURL.path) {
            return SessionMetadata(
                schemaVersion: currentSessionSchemaVersion,
                propertyID: propertyID,
                sessionID: sessionID,
                propertyNameAtCapture: nil,
                propertyNameAtExport: nil,
                startedAt: Date(),
                endedAt: nil,
                status: .draft,
                isBaselineSession: false,
                exportedAt: nil,
                isSealed: false,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil,
                appVersion: appVersionString(),
                deviceModel: deviceModelString(),
                osVersion: osVersionString(),
                shots: [],
                issues: []
            )
        }

        do {
            let data = try Data(contentsOf: fileURL)
            var metadata = try decoder.decode(SessionMetadata.self, from: data)
            metadata.schemaVersion = max(metadata.schemaVersion, currentSessionSchemaVersion)
            metadata.propertyID = propertyID
            metadata.sessionID = sessionID
            metadata.appVersion = metadata.appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? appVersionString()
                : metadata.appVersion
            metadata.deviceModel = metadata.deviceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? deviceModelString()
                : metadata.deviceModel
            metadata.osVersion = metadata.osVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? osVersionString()
                : metadata.osVersion
            metadata.shots = metadata.shots.map { shot in
                normalizeShotMetadata(shot, propertyID: propertyID, sessionID: sessionID)
            }
            return metadata
        } catch {
            print("Recoverable session metadata decode failure for session \(sessionID): \(error)")
            return SessionMetadata(
                schemaVersion: currentSessionSchemaVersion,
                propertyID: propertyID,
                sessionID: sessionID,
                propertyNameAtCapture: nil,
                propertyNameAtExport: nil,
                startedAt: Date(),
                endedAt: nil,
                status: .draft,
                isBaselineSession: false,
                exportedAt: nil,
                isSealed: false,
                firstDeliveredAt: nil,
                reExportExpiresAt: nil,
                appVersion: appVersionString(),
                deviceModel: deviceModelString(),
                osVersion: osVersionString(),
                shots: [],
                issues: []
            )
        }
    }

    private func writeSessionMetadata(_ metadata: SessionMetadata) throws {
        let propertyID = metadata.propertyID
        let sessionID = metadata.sessionID
        let folder = sessionMetadataFolderURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try ensureSessionFileStorage(propertyID: propertyID, sessionID: sessionID)
        let fileURL = sessionMetadataFileURL(propertyID: propertyID, sessionID: sessionID)
        let tempURL = folder.appendingPathComponent("session-\(UUID().uuidString).tmp")
        let data = try encoder.encode(metadata)
        try data.write(to: tempURL, options: .atomic)

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL, backupItemName: nil, options: [.usingNewMetadataOnly])
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
            throw error
        }
    }

    private func sessionMetadataFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionFolderURL(propertyID: propertyID, sessionID: sessionID)
    }

    private func sessionMetadataFileURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionJSONURL(propertyID: propertyID, sessionID: sessionID)
    }

    private func appVersionString() -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where !s.isEmpty && !b.isEmpty:
            return "\(s) (\(b))"
        case let (s?, _):
            return s
        case let (_, b?):
            return b
        default:
            return "unknown"
        }
    }

    private func deviceModelString() -> String {
        UIDevice.current.model
    }

    private func osVersionString() -> String {
        UIDevice.current.systemVersion
    }

    private func isBaselineSession(sessionID: UUID, propertyID: UUID) -> Bool {
        let properties = (try? readProperties()) ?? []
        return properties.first(where: { $0.id == propertyID })?.baselineSessionID == sessionID
    }

    private func currentPropertyName(for propertyID: UUID) -> String {
        let properties = (try? readProperties()) ?? []
        let value = properties.first(where: { $0.id == propertyID })?.name ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeShotMetadata(_ shot: ShotMetadata, propertyID: UUID, sessionID: UUID) -> ShotMetadata {
        let fileName = URL(fileURLWithPath: shot.originalFilename).lastPathComponent
        let normalizedFilename = fileName.isEmpty ? shot.originalFilename : fileName
        let normalizedRelativePath = shot.originalRelativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Originals/\(normalizedFilename)"
            : shot.originalRelativePath
        let normalizedShotKey = shot.shotKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ShotMetadata.makeShotKey(
                building: shot.building,
                elevation: shot.elevation,
                detailType: shot.detailType,
                angleIndex: shot.angleIndex
            )
            : shot.shotKey
        let normalizedStampedFilename = shot.stampedFilename.map { URL(fileURLWithPath: $0).lastPathComponent }
        let normalizedStampedPath: String?
        if let stamped = shot.stampedRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines), !stamped.isEmpty {
            normalizedStampedPath = stamped
        } else if let stampedName = normalizedStampedFilename, !stampedName.isEmpty {
            normalizedStampedPath = "Stamped/\(stampedName)"
        } else {
            normalizedStampedPath = nil
        }
        return ShotMetadata(
            shotID: shot.shotID,
            propertyID: propertyID,
            sessionID: sessionID,
            createdAt: shot.createdAt,
            updatedAt: shot.updatedAt,
            building: shot.building,
            elevation: CanonicalElevation.normalize(shot.elevation) ?? shot.elevation,
            detailType: shot.detailType,
            angleIndex: max(1, shot.angleIndex),
            shotKey: normalizedShotKey,
            isGuided: shot.isGuided,
            isFlagged: shot.isFlagged,
            issueID: shot.issueID,
            issueStatus: shot.issueStatus,
            noteText: shot.noteText,
            noteCategory: shot.noteCategory,
            originalFilename: normalizedFilename,
            originalRelativePath: normalizedRelativePath,
            originalByteSize: shot.originalByteSize,
            stampedFilename: normalizedStampedFilename,
            stampedRelativePath: normalizedStampedPath,
            captureMode: shot.captureMode,
            lens: shot.lens,
            orientation: shot.orientation,
            latitude: shot.latitude,
            longitude: shot.longitude,
            accuracyMeters: shot.accuracyMeters,
            imageWidth: shot.imageWidth,
            imageHeight: shot.imageHeight
        )
    }

    private func hasLegacyElevationValues(in fileURL: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.range(
            of: #""targetElevation"\s*:\s*"(North|South|East|West)\s+Elevation""#,
            options: .regularExpression
        ) != nil
    }
}

#if DEBUG
extension LocalStore {
    func printSessionSchema() {
        let sampleSession = SessionMetadata(
            schemaVersion: 4,
            propertyID: UUID(),
            sessionID: UUID(),
            propertyNameAtCapture: nil,
            propertyNameAtExport: nil,
            startedAt: Date(),
            endedAt: nil,
            status: .draft,
            isBaselineSession: false,
            exportedAt: nil,
            appVersion: "debug",
            deviceModel: "debug",
            osVersion: "debug",
            shots: [],
            issues: []
        )

        let sampleShot = ShotMetadata(
            shotID: UUID(),
            propertyID: UUID(),
            sessionID: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            building: "",
            elevation: "",
            detailType: "",
            angleIndex: 1,
            shotKey: "",
            isGuided: false,
            isFlagged: false,
            issueID: nil,
            issueStatus: nil,
            noteText: nil,
            noteCategory: nil,
            originalFilename: "",
            originalRelativePath: "",
            originalByteSize: nil,
            stampedFilename: nil,
            stampedRelativePath: nil,
            captureMode: nil,
            lens: nil,
            orientation: nil,
            latitude: nil,
            longitude: nil,
            accuracyMeters: nil,
            imageWidth: nil,
            imageHeight: nil
        )

        print("---- SessionMetadata Fields ----")
        for child in Mirror(reflecting: sampleSession).children {
            if let label = child.label {
                print(label)
            }
        }

        print("")
        print("---- ShotMetadata Fields ----")
        for child in Mirror(reflecting: sampleShot).children {
            if let label = child.label {
                print(label)
            }
        }
    }
}
#endif
