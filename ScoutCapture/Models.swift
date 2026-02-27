import Foundation
import UIKit

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

struct SessionMetadata: Codable {
    var schemaVersion: Int
    var propertyID: UUID
    var sessionID: UUID
    var propertyNameAtCapture: String?
    var propertyNameAtExport: String?
    var startedAt: Date
    var endedAt: Date?
    var status: Session.Status
    var isBaselineSession: Bool
    var exportedAt: Date?
    var appVersion: String
    var deviceModel: String
    var osVersion: String
    var shots: [ShotMetadata]
    var issues: [IssueMetadata]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case propertyID
        case sessionID
        case propertyNameAtCapture
        case propertyNameAtExport
        case startedAt
        case endedAt
        case status
        case isBaselineSession
        case exportedAt
        case appVersion
        case deviceModel
        case osVersion
        case shots
        case issues
    }

    init(
        schemaVersion: Int,
        propertyID: UUID,
        sessionID: UUID,
        propertyNameAtCapture: String?,
        propertyNameAtExport: String?,
        startedAt: Date,
        endedAt: Date?,
        status: Session.Status,
        isBaselineSession: Bool,
        exportedAt: Date?,
        appVersion: String,
        deviceModel: String,
        osVersion: String,
        shots: [ShotMetadata],
        issues: [IssueMetadata]
    ) {
        self.schemaVersion = schemaVersion
        self.propertyID = propertyID
        self.sessionID = sessionID
        self.propertyNameAtCapture = propertyNameAtCapture
        self.propertyNameAtExport = propertyNameAtExport
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.isBaselineSession = isBaselineSession
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.shots = shots
        self.issues = issues
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        propertyID = try c.decode(UUID.self, forKey: .propertyID)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        propertyNameAtCapture = try c.decodeIfPresent(String.self, forKey: .propertyNameAtCapture)
        propertyNameAtExport = try c.decodeIfPresent(String.self, forKey: .propertyNameAtExport)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        status = try c.decodeIfPresent(Session.Status.self, forKey: .status) ?? .draft
        isBaselineSession = try c.decodeIfPresent(Bool.self, forKey: .isBaselineSession) ?? false
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "unknown"
        deviceModel = try c.decodeIfPresent(String.self, forKey: .deviceModel) ?? "unknown"
        osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion) ?? "unknown"
        shots = try c.decodeIfPresent([ShotMetadata].self, forKey: .shots) ?? []
        issues = try c.decodeIfPresent([IssueMetadata].self, forKey: .issues) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(propertyID, forKey: .propertyID)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(propertyNameAtCapture, forKey: .propertyNameAtCapture)
        try c.encodeIfPresent(propertyNameAtExport, forKey: .propertyNameAtExport)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(status, forKey: .status)
        try c.encode(isBaselineSession, forKey: .isBaselineSession)
        try c.encodeIfPresent(exportedAt, forKey: .exportedAt)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(deviceModel, forKey: .deviceModel)
        try c.encode(osVersion, forKey: .osVersion)
        try c.encode(shots, forKey: .shots)
        try c.encode(issues, forKey: .issues)
    }
}

struct ShotMetadata: Codable, Identifiable, Equatable {
    let shotID: UUID
    let propertyID: UUID
    let sessionID: UUID
    let createdAt: Date
    var updatedAt: Date
    var building: String
    var elevation: String
    var detailType: String
    var angleIndex: Int
    var shotKey: String
    var isGuided: Bool
    var isFlagged: Bool
    var issueID: UUID?
    var issueStatus: String?
    var noteText: String?
    var noteCategory: String?
    var originalFilename: String
    var originalRelativePath: String
    var originalByteSize: Int?
    var stampedFilename: String?
    var stampedRelativePath: String?
    var captureMode: String?
    var lens: String?
    var orientation: String?
    var latitude: Double?
    var longitude: Double?
    var accuracyMeters: Double?
    var imageWidth: Int?
    var imageHeight: Int?

    var id: UUID { shotID }

    private enum CodingKeys: String, CodingKey {
        case shotID
        case propertyID
        case sessionID
        case createdAt
        case updatedAt
        case building
        case elevation
        case detailType
        case angleIndex
        case shotKey
        case isGuided
        case isFlagged
        case issueID
        case issueStatus
        case noteText
        case noteCategory
        case originalFilename
        case originalRelativePath
        case originalByteSize
        case stampedFilename
        case stampedRelativePath
        case captureMode
        case lens
        case orientation
        case latitude
        case longitude
        case accuracyMeters
        case imageWidth
        case imageHeight
    }

    init(
        shotID: UUID,
        propertyID: UUID,
        sessionID: UUID,
        createdAt: Date,
        updatedAt: Date,
        building: String,
        elevation: String,
        detailType: String,
        angleIndex: Int,
        shotKey: String,
        isGuided: Bool,
        isFlagged: Bool,
        issueID: UUID?,
        issueStatus: String?,
        noteText: String?,
        noteCategory: String?,
        originalFilename: String,
        originalRelativePath: String,
        originalByteSize: Int?,
        stampedFilename: String?,
        stampedRelativePath: String?,
        captureMode: String?,
        lens: String?,
        orientation: String?,
        latitude: Double?,
        longitude: Double?,
        accuracyMeters: Double?,
        imageWidth: Int?,
        imageHeight: Int?
    ) {
        self.shotID = shotID
        self.propertyID = propertyID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.building = building
        self.elevation = elevation
        self.detailType = detailType
        self.angleIndex = angleIndex
        self.shotKey = shotKey
        self.isGuided = isGuided
        self.isFlagged = isFlagged
        self.issueID = issueID
        self.issueStatus = issueStatus
        self.noteText = noteText
        self.noteCategory = noteCategory
        self.originalFilename = originalFilename
        self.originalRelativePath = originalRelativePath
        self.originalByteSize = originalByteSize
        self.stampedFilename = stampedFilename
        self.stampedRelativePath = stampedRelativePath
        self.captureMode = captureMode
        self.lens = lens
        self.orientation = orientation
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shotID = try c.decode(UUID.self, forKey: .shotID)
        propertyID = try c.decode(UUID.self, forKey: .propertyID)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        building = try c.decodeIfPresent(String.self, forKey: .building) ?? ""
        elevation = CanonicalElevation.normalize(try c.decodeIfPresent(String.self, forKey: .elevation)) ?? ""
        detailType = try c.decodeIfPresent(String.self, forKey: .detailType) ?? ""
        angleIndex = max(1, try c.decodeIfPresent(Int.self, forKey: .angleIndex) ?? 1)
        let decodedShotKey = try c.decodeIfPresent(String.self, forKey: .shotKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        shotKey = decodedShotKey.isEmpty
            ? ShotMetadata.makeShotKey(building: building, elevation: elevation, detailType: detailType, angleIndex: angleIndex)
            : decodedShotKey
        isGuided = try c.decodeIfPresent(Bool.self, forKey: .isGuided) ?? false
        isFlagged = try c.decodeIfPresent(Bool.self, forKey: .isFlagged) ?? false
        issueID = try c.decodeIfPresent(UUID.self, forKey: .issueID)
        issueStatus = try c.decodeIfPresent(String.self, forKey: .issueStatus)
        noteText = try c.decodeIfPresent(String.self, forKey: .noteText)
        noteCategory = try c.decodeIfPresent(String.self, forKey: .noteCategory)
        originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename) ?? ""
        let decodedRelative = try c.decodeIfPresent(String.self, forKey: .originalRelativePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if decodedRelative.isEmpty {
            let fallbackName = URL(fileURLWithPath: originalFilename).lastPathComponent
            originalRelativePath = fallbackName.isEmpty ? "" : "Originals/\(fallbackName)"
        } else {
            originalRelativePath = decodedRelative
        }
        originalByteSize = try c.decodeIfPresent(Int.self, forKey: .originalByteSize)
        stampedFilename = try c.decodeIfPresent(String.self, forKey: .stampedFilename)
        let decodedStampedRelative = try c.decodeIfPresent(String.self, forKey: .stampedRelativePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if decodedStampedRelative.isEmpty, let stampedFilename {
            let fallbackName = URL(fileURLWithPath: stampedFilename).lastPathComponent
            stampedRelativePath = fallbackName.isEmpty ? nil : "Stamped/\(fallbackName)"
        } else {
            stampedRelativePath = decodedStampedRelative.isEmpty ? nil : decodedStampedRelative
        }
        captureMode = try c.decodeIfPresent(String.self, forKey: .captureMode)
        lens = try c.decodeIfPresent(String.self, forKey: .lens)
        orientation = try c.decodeIfPresent(String.self, forKey: .orientation)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        accuracyMeters = try c.decodeIfPresent(Double.self, forKey: .accuracyMeters)
        imageWidth = try c.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try c.decodeIfPresent(Int.self, forKey: .imageHeight)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shotID, forKey: .shotID)
        try c.encode(propertyID, forKey: .propertyID)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(building, forKey: .building)
        try c.encode(CanonicalElevation.normalize(elevation) ?? elevation, forKey: .elevation)
        try c.encode(detailType, forKey: .detailType)
        try c.encode(max(1, angleIndex), forKey: .angleIndex)
        let encodedKey = shotKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try c.encode(encodedKey.isEmpty ? ShotMetadata.makeShotKey(building: building, elevation: elevation, detailType: detailType, angleIndex: angleIndex) : encodedKey, forKey: .shotKey)
        try c.encode(isGuided, forKey: .isGuided)
        try c.encode(isFlagged, forKey: .isFlagged)
        try c.encodeIfPresent(issueID, forKey: .issueID)
        try c.encodeIfPresent(issueStatus, forKey: .issueStatus)
        try c.encodeIfPresent(noteText, forKey: .noteText)
        try c.encodeIfPresent(noteCategory, forKey: .noteCategory)
        try c.encode(originalFilename, forKey: .originalFilename)
        try c.encode(originalRelativePath, forKey: .originalRelativePath)
        try c.encodeIfPresent(originalByteSize, forKey: .originalByteSize)
        try c.encodeIfPresent(stampedFilename, forKey: .stampedFilename)
        try c.encodeIfPresent(stampedRelativePath, forKey: .stampedRelativePath)
        try c.encodeIfPresent(captureMode, forKey: .captureMode)
        try c.encodeIfPresent(lens, forKey: .lens)
        try c.encodeIfPresent(orientation, forKey: .orientation)
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encodeIfPresent(accuracyMeters, forKey: .accuracyMeters)
        try c.encodeIfPresent(imageWidth, forKey: .imageWidth)
        try c.encodeIfPresent(imageHeight, forKey: .imageHeight)
    }

    static func makeShotKey(building: String, elevation: String, detailType: String, angleIndex: Int) -> String {
        let normalizedBuilding = normalizeKeyPart(building)
        let normalizedElevation = normalizeKeyPart(CanonicalElevation.normalize(elevation) ?? elevation)
        let normalizedDetailType = normalizeKeyPart(detailType)
        let normalizedAngle = String(max(1, angleIndex))
        return "\(normalizedBuilding)|\(normalizedElevation)|\(normalizedDetailType)|\(normalizedAngle)"
    }

    private static func normalizeKeyPart(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct IssueMetadata: Codable, Identifiable, Equatable {
    let issueID: UUID
    var status: Observation.Status
    var statement: String

    var id: UUID { issueID }
}

struct Property: Codable, Identifiable, Equatable {
    let id: UUID
    var clientName: String?
    var clientPhone: String?
    var name: String
    var address: String?
    var baselineSessionID: UUID?
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        clientName: String? = nil,
        clientPhone: String? = nil,
        name: String,
        address: String? = nil,
        baselineSessionID: UUID? = nil,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.clientName = clientName
        self.clientPhone = clientPhone
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
        case clientPhone
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
        clientPhone = try c.decodeIfPresent(String.self, forKey: .clientPhone)
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
        try c.encodeIfPresent(clientPhone, forKey: .clientPhone)
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

struct ReportAsset: Identifiable, Equatable {
    let localIdentifier: String
    let fileURL: URL
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let originalFilename: String

    var id: String { localIdentifier }
}
