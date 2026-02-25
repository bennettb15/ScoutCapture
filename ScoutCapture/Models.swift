import Foundation

enum CanonicalElevation {
    static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()

        if lowered == "north elevation" || lowered == "north" { return "North" }
        if lowered == "south elevation" || lowered == "south" { return "South" }
        if lowered == "east elevation" || lowered == "east" { return "East" }
        if lowered == "west elevation" || lowered == "west" { return "West" }
        return trimmed
    }
}

struct Property: Codable, Identifiable, Equatable {
    let id: UUID
    var clientName: String?
    var name: String
    var address: String?
    var baselineSessionID: UUID?
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        clientName: String? = nil,
        name: String,
        address: String? = nil,
        baselineSessionID: UUID? = nil,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.clientName = clientName
        self.name = name
        self.address = address
        self.baselineSessionID = baselineSessionID
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case clientName
        case name
        case address
        case baselineSessionID
        case isArchived
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        clientName = try c.decodeIfPresent(String.self, forKey: .clientName)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        baselineSessionID = try c.decodeIfPresent(UUID.self, forKey: .baselineSessionID)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(clientName, forKey: .clientName)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(address, forKey: .address)
        try c.encodeIfPresent(baselineSessionID, forKey: .baselineSessionID)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

struct Session: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case draft
        case completed
    }

    let id: UUID
    let propertyID: UUID
    var startedAt: Date
    var status: Status
    var endedAt: Date?
    var exportedAt: Date?
    var notes: String?

    init(
        id: UUID = UUID(),
        propertyID: UUID,
        startedAt: Date = Date(),
        status: Status = .draft,
        endedAt: Date? = nil,
        exportedAt: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.propertyID = propertyID
        self.startedAt = startedAt
        self.status = status
        self.endedAt = endedAt
        self.exportedAt = exportedAt
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case propertyID
        case startedAt
        case status
        case endedAt
        case exportedAt
        case notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        propertyID = try c.decode(UUID.self, forKey: .propertyID)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        if let decodedStatus = try c.decodeIfPresent(Status.self, forKey: .status) {
            status = decodedStatus
        } else {
            // Legacy migration for existing sessions persisted before explicit status existed.
            status = (endedAt == nil) ? .draft : .completed
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(propertyID, forKey: .propertyID)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(exportedAt, forKey: .exportedAt)
        try c.encodeIfPresent(notes, forKey: .notes)
    }
}

enum SkipReason: String, Codable, CaseIterable {
    case inaccessible
    case obstructed
    case activeConstruction
    case safetyConcern
    case other

    // Legacy values retained for backwards compatibility with existing saved data.
    case notVisible
    case unsafe
    case blocked
    case notApplicable
}

struct Shot: Codable, Identifiable, Equatable {
    let id: UUID
    var capturedAt: Date
    var imageLocalIdentifier: String?
    var note: String?

    init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        imageLocalIdentifier: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.imageLocalIdentifier = imageLocalIdentifier
        self.note = note
    }
}

struct GuidedShot: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var building: String?
    var targetElevation: String?
    var detailType: String?
    var angleIndex: Int?
    var referenceImageLocalIdentifier: String?
    var referenceImagePath: String?
    var shot: Shot?
    var isCompleted: Bool
    var skipReason: SkipReason?
    var skipReasonNote: String?
    var skipSessionID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        building: String? = nil,
        targetElevation: String? = nil,
        detailType: String? = nil,
        angleIndex: Int? = nil,
        referenceImageLocalIdentifier: String? = nil,
        referenceImagePath: String? = nil,
        shot: Shot? = nil,
        isCompleted: Bool = false,
        skipReason: SkipReason? = nil,
        skipReasonNote: String? = nil,
        skipSessionID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.building = building
        self.targetElevation = targetElevation
        self.detailType = detailType
        self.angleIndex = angleIndex
        self.referenceImageLocalIdentifier = referenceImageLocalIdentifier
        self.referenceImagePath = referenceImagePath
        self.shot = shot
        self.isCompleted = isCompleted
        self.skipReason = skipReason
        self.skipReasonNote = skipReasonNote
        self.skipSessionID = skipSessionID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case building
        case targetElevation
        case detailType
        case angleIndex
        case referenceImageLocalIdentifier
        case referenceImagePath
        case shot
        case isCompleted
        case skipReason
        case skipReasonNote
        case skipSessionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        building = try c.decodeIfPresent(String.self, forKey: .building)
        targetElevation = CanonicalElevation.normalize(try c.decodeIfPresent(String.self, forKey: .targetElevation))
        detailType = try c.decodeIfPresent(String.self, forKey: .detailType)
        angleIndex = try c.decodeIfPresent(Int.self, forKey: .angleIndex)
        referenceImageLocalIdentifier = try c.decodeIfPresent(String.self, forKey: .referenceImageLocalIdentifier)
        referenceImagePath = try c.decodeIfPresent(String.self, forKey: .referenceImagePath)
        shot = try c.decodeIfPresent(Shot.self, forKey: .shot)
        isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        skipReason = try c.decodeIfPresent(SkipReason.self, forKey: .skipReason)
        skipReasonNote = try c.decodeIfPresent(String.self, forKey: .skipReasonNote)
        skipSessionID = try c.decodeIfPresent(UUID.self, forKey: .skipSessionID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(building, forKey: .building)
        try c.encodeIfPresent(CanonicalElevation.normalize(targetElevation), forKey: .targetElevation)
        try c.encodeIfPresent(detailType, forKey: .detailType)
        try c.encodeIfPresent(angleIndex, forKey: .angleIndex)
        try c.encodeIfPresent(referenceImageLocalIdentifier, forKey: .referenceImageLocalIdentifier)
        try c.encodeIfPresent(referenceImagePath, forKey: .referenceImagePath)
        try c.encodeIfPresent(shot, forKey: .shot)
        try c.encode(isCompleted, forKey: .isCompleted)
        try c.encodeIfPresent(skipReason, forKey: .skipReason)
        try c.encodeIfPresent(skipReasonNote, forKey: .skipReasonNote)
        try c.encodeIfPresent(skipSessionID, forKey: .skipSessionID)
    }
}

struct Observation: Codable, Identifiable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case active = "Active"
        case resolved = "Resolved"
    }

    let id: UUID
    let propertyID: UUID
    let sessionID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var statement: String
    var status: Status
    var linkedShotID: UUID?
    var resolutionPhotoRef: String?
    var resolutionStatement: String?
    var updatedInSessionID: UUID?
    var resolvedInSessionID: UUID?
    var building: String?
    var targetElevation: String?
    var detailType: String?
    var updateHistory: [ObservationUpdateEntry]
    var note: String?
    var shots: [Shot]
    var guidedShots: [GuidedShot]

    init(
        id: UUID = UUID(),
        propertyID: UUID,
        sessionID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        statement: String = "",
        status: Status = .active,
        linkedShotID: UUID? = nil,
        resolutionPhotoRef: String? = nil,
        resolutionStatement: String? = nil,
        updatedInSessionID: UUID? = nil,
        resolvedInSessionID: UUID? = nil,
        building: String? = nil,
        targetElevation: String? = nil,
        detailType: String? = nil,
        updateHistory: [ObservationUpdateEntry] = [],
        note: String? = nil,
        shots: [Shot] = [],
        guidedShots: [GuidedShot] = []
    ) {
        self.id = id
        self.propertyID = propertyID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.statement = statement
        self.status = status
        self.linkedShotID = linkedShotID
        self.resolutionPhotoRef = resolutionPhotoRef
        self.resolutionStatement = resolutionStatement
        self.updatedInSessionID = updatedInSessionID
        self.resolvedInSessionID = resolvedInSessionID
        self.building = building
        self.targetElevation = targetElevation
        self.detailType = detailType
        self.updateHistory = updateHistory
        self.note = note
        self.shots = shots
        self.guidedShots = guidedShots
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case propertyID
        case sessionID
        case createdAt
        case updatedAt
        case statement
        case status
        case linkedShotID
        case resolutionPhotoRef
        case resolutionStatement
        case updatedInSessionID
        case resolvedInSessionID
        case building
        case targetElevation
        case detailType
        case updateHistory
        case note
        case shots
        case guidedShots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        propertyID = try c.decode(UUID.self, forKey: .propertyID)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        statement = try c.decode(String.self, forKey: .statement)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .active
        linkedShotID = try c.decodeIfPresent(UUID.self, forKey: .linkedShotID)
        resolutionPhotoRef = try c.decodeIfPresent(String.self, forKey: .resolutionPhotoRef)
        resolutionStatement = try c.decodeIfPresent(String.self, forKey: .resolutionStatement)
        updatedInSessionID = try c.decodeIfPresent(UUID.self, forKey: .updatedInSessionID)
        resolvedInSessionID = try c.decodeIfPresent(UUID.self, forKey: .resolvedInSessionID)
        building = try c.decodeIfPresent(String.self, forKey: .building)
        targetElevation = CanonicalElevation.normalize(try c.decodeIfPresent(String.self, forKey: .targetElevation))
        detailType = try c.decodeIfPresent(String.self, forKey: .detailType)
        updateHistory = try c.decodeIfPresent([ObservationUpdateEntry].self, forKey: .updateHistory) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
        shots = try c.decodeIfPresent([Shot].self, forKey: .shots) ?? []
        guidedShots = try c.decodeIfPresent([GuidedShot].self, forKey: .guidedShots) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(propertyID, forKey: .propertyID)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(statement, forKey: .statement)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(linkedShotID, forKey: .linkedShotID)
        try c.encodeIfPresent(resolutionPhotoRef, forKey: .resolutionPhotoRef)
        try c.encodeIfPresent(resolutionStatement, forKey: .resolutionStatement)
        try c.encodeIfPresent(updatedInSessionID, forKey: .updatedInSessionID)
        try c.encodeIfPresent(resolvedInSessionID, forKey: .resolvedInSessionID)
        try c.encodeIfPresent(building, forKey: .building)
        try c.encodeIfPresent(CanonicalElevation.normalize(targetElevation), forKey: .targetElevation)
        try c.encodeIfPresent(detailType, forKey: .detailType)
        try c.encode(updateHistory, forKey: .updateHistory)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(shots, forKey: .shots)
        try c.encode(guidedShots, forKey: .guidedShots)
    }
}

struct ObservationUpdateEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case followUpCapture
        case revisedObservation
    }

    let id: UUID
    let createdAt: Date
    var kind: Kind
    var text: String?
    var shotID: UUID?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: Kind,
        text: String? = nil,
        shotID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.shotID = shotID
    }
}
