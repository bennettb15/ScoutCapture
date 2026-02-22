import Foundation

final class LocalStore {
    enum StoreError: Error {
        case propertyNotFound(UUID)
        case observationNotFound(UUID)
    }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let propertiesURL: URL
    private let observationsDirectoryURL: URL

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
        self.propertiesURL = baseDirectory.appendingPathComponent("properties.json")
        self.observationsDirectoryURL = baseDirectory.appendingPathComponent("observations", isDirectory: true)

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
        var properties = try readProperties()
        properties.removeAll { $0.id == id }
        try writeProperties(properties)

        let propertyObservationURL = observationsFileURL(for: id)
        if fileManager.fileExists(atPath: propertyObservationURL.path) {
            try fileManager.removeItem(at: propertyObservationURL)
        }
    }

    // MARK: - Observations CRUD (per-property)

    func fetchObservations(propertyID: UUID) throws -> [Observation] {
        try ensurePropertyExists(propertyID)
        return try readObservations(propertyID: propertyID)
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

    // MARK: - Private Helpers

    private func createStorageDirectories(baseDirectoryURL: URL) throws {
        if !fileManager.fileExists(atPath: baseDirectoryURL.path) {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: observationsDirectoryURL.path) {
            try fileManager.createDirectory(at: observationsDirectoryURL, withIntermediateDirectories: true)
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
}
