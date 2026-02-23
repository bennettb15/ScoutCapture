import Foundation

struct Property: Codable, Identifiable, Equatable {
    let id: UUID
    var clientName: String?
    var name: String
    var address: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        clientName: String? = nil,
        name: String,
        address: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.clientName = clientName
        self.name = name
        self.address = address
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct Session: Codable, Identifiable, Equatable {
    let id: UUID
    let propertyID: UUID
    var startedAt: Date
    var endedAt: Date?
    var notes: String?

    init(
        id: UUID = UUID(),
        propertyID: UUID,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.propertyID = propertyID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.notes = notes
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
    var referenceImageLocalIdentifier: String?
    var shot: Shot?
    var isCompleted: Bool
    var skipReason: SkipReason?
    var skipReasonNote: String?

    init(
        id: UUID = UUID(),
        title: String,
        building: String? = nil,
        targetElevation: String? = nil,
        referenceImageLocalIdentifier: String? = nil,
        shot: Shot? = nil,
        isCompleted: Bool = false,
        skipReason: SkipReason? = nil,
        skipReasonNote: String? = nil
    ) {
        self.id = id
        self.title = title
        self.building = building
        self.targetElevation = targetElevation
        self.referenceImageLocalIdentifier = referenceImageLocalIdentifier
        self.shot = shot
        self.isCompleted = isCompleted
        self.skipReason = skipReason
        self.skipReasonNote = skipReasonNote
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
        self.note = note
        self.shots = shots
        self.guidedShots = guidedShots
    }
}
