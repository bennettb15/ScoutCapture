import Foundation

enum FieldResolutionReviewPolicy {
    struct RemoteRow: Decodable {
        let requiresReview: Bool?

        enum CodingKeys: String, CodingKey {
            case requiresReview = "require_review_for_field_resolutions"
        }
    }

    static func requiresReview(organizationID: UUID?, defaults: UserDefaults) -> Bool {
        guard let organizationID else { return true }
        return defaults.object(forKey: cacheKey(organizationID)) as? Bool ?? true
    }

    static func cache(_ requiresReview: Bool?, organizationID: UUID, defaults: UserDefaults) {
        if let requiresReview {
            defaults.set(requiresReview, forKey: cacheKey(organizationID))
        } else {
            defaults.removeObject(forKey: cacheKey(organizationID))
        }
    }

    private static func cacheKey(_ organizationID: UUID) -> String {
        "scoutcapture.fieldResolutionReview.\(organizationID.uuidString.lowercased())"
    }
}

/// A server decision on one field submission, separate from a human review.
struct FieldResolutionOutcome: Equatable {
    nonisolated static let activityType = "field_resolution_finalized"
    nonisolated static let historyField = "field_resolution_outcome"

    let id: UUID
    let sessionID: UUID
    let shotID: UUID?
    let status: Observation.Status
    let createdAt: Date

    nonisolated init?(
        id: UUID, sessionValue: String?, shotID: UUID?, statusValue: String?, createdAt: Date?
    ) {
        guard let sessionValue, let sessionID = UUID(uuidString: sessionValue),
              let createdAt else { return nil }
        switch statusValue {
        case "pending_review": status = .pendingReview
        case "resolved": status = .resolved
        default: return nil
        }
        self.id = id
        self.sessionID = sessionID
        self.shotID = shotID
        self.createdAt = createdAt
    }
}

extension Observation {
    nonisolated static let fieldResolutionHistoryField = "field_resolution"

    mutating func recordFieldResolution(
        requiresReview: Bool,
        sessionID: UUID,
        shotID: UUID?,
        at timestamp: Date = Date()
    ) {
        let previousStatus = status
        status = requiresReview ? .pendingReview : .resolved
        updatedAt = timestamp
        updatedInSessionID = sessionID
        resolvedInSessionID = sessionID
        historyEvents.append(ObservationHistoryEvent(
            timestamp: timestamp,
            sessionID: sessionID,
            kind: requiresReview ? .pendingReview : .resolved,
            beforeValue: previousStatus.issueStatusValue,
            afterValue: status.issueStatusValue,
            field: Self.fieldResolutionHistoryField,
            shotID: shotID
        ))
        historyEvents.sort { $0.timestamp < $1.timestamp }
    }

    var latestFieldResolutionSubmission: ObservationHistoryEvent? {
        historyEvents
            .filter { $0.field == Self.fieldResolutionHistoryField }
            .max { $0.timestamp < $1.timestamp }
    }

    var hasFieldResolutionHistory: Bool {
        historyEvents.contains {
            $0.field == Self.fieldResolutionHistoryField || $0.field == FieldResolutionOutcome.historyField
        }
    }

    var preservesFieldResolutionStatus: Bool {
        (status == .pendingReview || status == .resolved) && hasFieldResolutionHistory
    }

    var fieldResolutionToast: String {
        status == .resolved ? "Issue resolved" : "Issue submitted for review"
    }

    func appearsInFieldIssueList(currentSessionID: UUID?) -> Bool {
        switch status {
        case .active, .pendingReview, .resolutionRequired:
            return true
        case .resolved:
            return preservesFieldResolutionStatus && currentSessionID != nil &&
                resolvedInSessionID == currentSessionID
        }
    }

    mutating func applyFieldResolutionOutcome(_ outcome: FieldResolutionOutcome) -> Bool {
        guard !historyEvents.contains(where: { $0.id == outcome.id }) else { return false }
        let submission = latestFieldResolutionSubmission
        let matchesSubmission = submission?.sessionID == outcome.sessionID &&
            submission?.shotID == outcome.shotID
        if let submission, !matchesSubmission,
           submission.sessionID == outcome.sessionID || submission.timestamp >= outcome.createdAt {
            return false
        }
        if historyEvents.contains(where: {
            ($0.kind == .reopened || $0.field == FieldResolutionOutcome.historyField) &&
                $0.timestamp >= outcome.createdAt
        }) { return false }
        let storedSubmissionSessionID = resolvedInSessionID ?? updatedInSessionID ?? sessionID
        let matchesRestoredEvidence = submission == nil && status != .active &&
            outcome.shotID != nil && linkedShotID == outcome.shotID &&
            (storedSubmissionSessionID == nil || storedSubmissionSessionID == outcome.sessionID)
        guard matchesSubmission || matchesRestoredEvidence || outcome.createdAt >= updatedAt else { return false }

        let before = status
        status = outcome.status
        updatedAt = max(updatedAt, outcome.createdAt)
        updatedInSessionID = outcome.sessionID
        resolvedInSessionID = outcome.sessionID
        if let shotID = outcome.shotID, linkedShotID != shotID {
            linkedShotID = shotID
            resolutionPhotoRef = shots.first { $0.id == shotID }?.imageLocalIdentifier
        }
        historyEvents.append(ObservationHistoryEvent(
            id: outcome.id,
            timestamp: outcome.createdAt,
            sessionID: outcome.sessionID,
            kind: status == .resolved ? .resolved : .pendingReview,
            beforeValue: before.issueStatusValue,
            afterValue: status.issueStatusValue,
            field: FieldResolutionOutcome.historyField,
            shotID: outcome.shotID
        ))
        historyEvents.sort { $0.timestamp < $1.timestamp }
        return true
    }
}

extension IssueMetadata {
    nonisolated func fieldResolutionSubmission(sessionID: UUID) -> IssueHistoryEvent? {
        historyEvents.filter {
            $0.sessionId == sessionID && $0.details["field"] == Observation.fieldResolutionHistoryField
        }.max { $0.timestamp < $1.timestamp }
    }

    /// Field resolution evidence is a submission until the server applies its policy.
    nonisolated func statusForUpload(sessionID: UUID) -> String {
        let status = Observation.Status.status(from: issueStatus)
        if status == .resolved && fieldResolutionSubmission(sessionID: sessionID) != nil {
            return Observation.Status.pendingReview.issueStatusValue
        }
        return status.issueStatusValue
    }
}

extension SessionMetadata {
    func shotForFieldResolutionUpload(_ shot: ShotMetadata) -> ShotMetadata {
        guard shot.issueStatus == Observation.Status.resolved.issueStatusValue,
              let issueID = shot.issueID,
              let issue = issues.first(where: { $0.issueID == issueID }),
              issue.statusForUpload(sessionID: shot.sessionID) == Observation.Status.pendingReview.issueStatusValue
        else { return shot }
        var submission = shot
        submission.issueStatus = Observation.Status.pendingReview.issueStatusValue
        return submission
    }
}
