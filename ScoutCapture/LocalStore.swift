import Foundation
import UIKit

final class LocalStore {
    enum StoreError: Error {
        case propertyNotFound(UUID)
        case observationNotFound(UUID)
        case sessionNotFound(UUID)
    }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let baseDirectoryURL: URL
    private let propertiesURL: URL
    private let observationsDirectoryURL: URL
    private let guidedShotsDirectoryURL: URL
    private let sessionsDirectoryURL: URL
    private let sessionMetadataDirectoryURL: URL

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
        let baseDirectory = appSupport.appendingPathComponent("ScoutCapture", isDirectory: true)
        self.baseDirectoryURL = baseDirectory
        self.propertiesURL = baseDirectory.appendingPathComponent("properties.json")
        self.observationsDirectoryURL = baseDirectory.appendingPathComponent("observations", isDirectory: true)
        self.guidedShotsDirectoryURL = baseDirectory.appendingPathComponent("guided-shots", isDirectory: true)
        self.sessionsDirectoryURL = baseDirectory.appendingPathComponent("sessions", isDirectory: true)
        self.sessionMetadataDirectoryURL = baseDirectory.appendingPathComponent("session-metadata", isDirectory: true)

        try? createStorageDirectories(baseDirectoryURL: baseDirectory)
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

        let propertySessionMetadataURL = sessionMetadataDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: propertySessionMetadataURL.path) {
            try? fileManager.removeItem(at: propertySessionMetadataURL)
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
        var metadata = try readOrRecoverSessionMetadata(propertyID: shot.propertyID, sessionID: shot.sessionID)
        metadata.schemaVersion = max(metadata.schemaVersion, 1)
        metadata.propertyID = shot.propertyID
        metadata.sessionID = shot.sessionID

        if let index = metadata.shots.firstIndex(where: { $0.shotID == shot.shotID }) {
            metadata.shots[index] = shot
        } else if shot.isGuided,
                  let index = metadata.shots.firstIndex(where: {
                      $0.isGuided &&
                      $0.propertyID == shot.propertyID &&
                      $0.sessionID == shot.sessionID &&
                      $0.building.caseInsensitiveCompare(shot.building) == .orderedSame &&
                      CanonicalElevation.normalize($0.elevation) == CanonicalElevation.normalize(shot.elevation) &&
                      $0.detailType.caseInsensitiveCompare(shot.detailType) == .orderedSame &&
                      $0.angleIndex == shot.angleIndex
                  }) {
            metadata.shots[index] = shot
        } else {
            metadata.shots.append(shot)
        }

        try writeSessionMetadata(metadata)
    }
    
    func latestDraftSession(propertyID: UUID) throws -> Session? {
        let sessions = try fetchSessions(propertyID: propertyID)
        return sessions
            .filter { $0.status == .draft }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }

    func deleteSession(id: UUID, propertyID: UUID) throws {
        try ensurePropertyExists(propertyID)
        var sessions = try readSessions(propertyID: propertyID)
        sessions.removeAll { $0.id == id }
        try writeSessions(sessions, propertyID: propertyID)
        let metadataFolder = sessionMetadataFolderURL(propertyID: propertyID, sessionID: id)
        if fileManager.fileExists(atPath: metadataFolder.path) {
            try? fileManager.removeItem(at: metadataFolder)
        }
    }

    func deleteSessionCascade(id: UUID, propertyID: UUID) throws {
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

    func wipeAllLocalData() throws {
        if fileManager.fileExists(atPath: baseDirectoryURL.path) {
            try fileManager.removeItem(at: baseDirectoryURL)
        }
        try createStorageDirectories(baseDirectoryURL: baseDirectoryURL)
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

        if !fileManager.fileExists(atPath: sessionMetadataDirectoryURL.path) {
            try fileManager.createDirectory(at: sessionMetadataDirectoryURL, withIntermediateDirectories: true)
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
        metadata.schemaVersion = 1
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
        metadata.exportedAt = session.exportedAt
        metadata.appVersion = appVersionString()
        metadata.deviceModel = deviceModelString()
        try writeSessionMetadata(metadata)
    }

    private func readOrRecoverSessionMetadata(propertyID: UUID, sessionID: UUID) throws -> SessionMetadata {
        let fileURL = sessionMetadataFileURL(propertyID: propertyID, sessionID: sessionID)
        if !fileManager.fileExists(atPath: fileURL.path) {
            return SessionMetadata(
                schemaVersion: 1,
                propertyID: propertyID,
                sessionID: sessionID,
                propertyNameAtCapture: nil,
                propertyNameAtExport: nil,
                startedAt: Date(),
                endedAt: nil,
                status: .draft,
                exportedAt: nil,
                appVersion: appVersionString(),
                deviceModel: deviceModelString(),
                shots: [],
                issues: []
            )
        }

        do {
            let data = try Data(contentsOf: fileURL)
            var metadata = try decoder.decode(SessionMetadata.self, from: data)
            metadata.schemaVersion = max(metadata.schemaVersion, 1)
            metadata.propertyID = propertyID
            metadata.sessionID = sessionID
            return metadata
        } catch {
            print("Recoverable session metadata decode failure for session \(sessionID): \(error)")
            return SessionMetadata(
                schemaVersion: 1,
                propertyID: propertyID,
                sessionID: sessionID,
                propertyNameAtCapture: nil,
                propertyNameAtExport: nil,
                startedAt: Date(),
                endedAt: nil,
                status: .draft,
                exportedAt: nil,
                appVersion: appVersionString(),
                deviceModel: deviceModelString(),
                shots: [],
                issues: []
            )
        }
    }

    private func writeSessionMetadata(_ metadata: SessionMetadata) throws {
        let folder = sessionMetadataFolderURL(propertyID: metadata.propertyID, sessionID: metadata.sessionID)
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let fileURL = sessionMetadataFileURL(propertyID: metadata.propertyID, sessionID: metadata.sessionID)
        let data = try encoder.encode(metadata)
        try data.write(to: fileURL, options: .atomic)
    }

    private func sessionMetadataFolderURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionMetadataDirectoryURL
            .appendingPathComponent(propertyID.uuidString, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    private func sessionMetadataFileURL(propertyID: UUID, sessionID: UUID) -> URL {
        sessionMetadataFolderURL(propertyID: propertyID, sessionID: sessionID)
            .appendingPathComponent("session.json")
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

    private func currentPropertyName(for propertyID: UUID) -> String {
        let properties = (try? readProperties()) ?? []
        let value = properties.first(where: { $0.id == propertyID })?.name ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
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
