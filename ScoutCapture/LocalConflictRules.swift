import Foundation

enum LocalConflictRules {
    // 2C-11 is intentionally a local deterministic conflict layer only.
    // Session lock ownership and any `locked_*` fields remain delegated to the
    // existing 2C-10b session coordination helpers and must not be routed
    // through these generic reducers.

    static func shouldApplyPropertyLastWriteWins(
        currentUpdatedAt: Date?,
        incomingUpdatedAt: Date
    ) -> Bool {
        guard let currentUpdatedAt else { return true }
        return incomingUpdatedAt > currentUpdatedAt
    }

    static func applyAppendOnlyMediaRef(
        current: [ShotMetadata],
        incoming: ShotMetadata
    ) -> [ShotMetadata] {
        var merged = current
        if let index = merged.firstIndex(where: { $0.shotID == incoming.shotID }) {
            merged[index] = incoming
        } else {
            merged.append(incoming)
        }
        return merged
    }

    static func applyGuidedCompletionState(
        current: [GuidedShot],
        incoming: GuidedShot
    ) -> [GuidedShot] {
        var merged = current
        if let index = merged.firstIndex(where: { $0.id == incoming.id }) {
            merged[index] = incoming
        } else {
            merged.append(incoming)
        }
        return merged
    }

    static func normalizeGuidedCompletionStates(
        _ guidedShots: [GuidedShot]
    ) -> [GuidedShot] {
        let mergedByID = guidedShots.reduce(into: [GuidedShot]()) { partial, guidedShot in
            partial = applyGuidedCompletionState(current: partial, incoming: guidedShot)
        }
        return applyResolvedGuidedPrecedence(mergedByID)
    }

    static func guidedShotIdentityKey(_ guidedShot: GuidedShot) -> String? {
        guidedShotIdentityKey(
            building: guidedShot.building,
            elevation: guidedShot.targetElevation,
            detailType: guidedShot.detailType,
            angleIndex: guidedShot.angleIndex
        )
    }

    static func guidedShotIdentityKey(
        building: String?,
        elevation: String?,
        detailType: String?,
        angleIndex: Int?
    ) -> String? {
        let normalizedBuilding = normalizedGuidedPart(building)
        let normalizedElevation = normalizedGuidedPart(CanonicalElevation.normalize(elevation) ?? elevation)
        let normalizedDetail = normalizedGuidedPart(detailType)
        guard !normalizedBuilding.isEmpty,
              !normalizedElevation.isEmpty,
              !normalizedDetail.isEmpty else {
            return nil
        }
        return [
            normalizedBuilding,
            normalizedElevation,
            normalizedDetail,
            "\(max(1, angleIndex ?? 1))"
        ].joined(separator: "|")
    }

    static func guidedShot(_ guidedShot: GuidedShot, matches shot: ShotMetadata) -> Bool {
        if guidedShot.id == shot.shotID || guidedShot.shot?.id == shot.shotID {
            return true
        }
        guard let guidedKey = guidedShotIdentityKey(guidedShot),
              let shotKey = guidedShotIdentityKey(
                building: shot.building,
                elevation: shot.elevation,
                detailType: shot.detailType,
                angleIndex: shot.angleIndex
              ) else {
            return false
        }
        return guidedKey == shotKey
    }

    private static func applyResolvedGuidedPrecedence(_ guidedShots: [GuidedShot]) -> [GuidedShot] {
        let latestResolvedByKey = guidedShots.reduce(into: [String: GuidedShot]()) { partial, guided in
            guard guided.status == .retired || guided.isRetired,
                  let key = guidedShotIdentityKey(guided) else {
                return
            }
            guard let existing = partial[key],
                  guidedKnownStateAt(existing) >= guidedKnownStateAt(guided) else {
                partial[key] = guided
                return
            }
        }

        guard !latestResolvedByKey.isEmpty else { return guidedShots }

        return guidedShots.map { guided in
            guard guided.status != .retired,
                  !guided.isRetired,
                  let key = guidedShotIdentityKey(guided),
                  let resolved = latestResolvedByKey[key],
                  guidedKnownStateAt(resolved) >= guidedKnownStateAt(guided) else {
                return guided
            }

            var suppressed = guided
            suppressed.status = .retired
            suppressed.isRetired = true
            suppressed.retiredAt = resolved.retiredAt ?? guidedKnownStateAt(resolved)
            suppressed.retiredInSessionID = resolved.retiredInSessionID ?? guided.retiredInSessionID
            suppressed.skipReason = nil
            suppressed.skipReasonNote = nil
            suppressed.skipSessionID = nil
            if suppressed.referenceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                suppressed.referenceImagePath = resolved.referenceImagePath
            }
            if suppressed.referenceImageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                suppressed.referenceImageLocalIdentifier = resolved.referenceImageLocalIdentifier
            }
            return suppressed
        }
    }

    private static func guidedKnownStateAt(_ guidedShot: GuidedShot) -> Date {
        [
            guidedShot.retiredAt,
            guidedShot.reassignedAt,
            guidedShot.labelEditedAt,
            guidedShot.shot?.capturedAt
        ]
        .compactMap { $0 }
        .max() ?? .distantPast
    }

    private static func normalizedGuidedPart(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    static func reconcileObservationStatus(
        current: Observation,
        incoming: Observation
    ) -> Observation {
        let incomingWins = incoming.updatedAt > current.updatedAt
        var merged = incomingWins ? incoming : current

        merged.updatedAt = max(current.updatedAt, incoming.updatedAt)
        merged.status = incomingWins ? incoming.status : current.status
        merged.historyEvents = normalizeObservationHistoryEventsAppendOnly(
            current.historyEvents + incoming.historyEvents
        )
        merged.updateHistory = normalizeObservationUpdateEntriesAppendOnly(
            current.updateHistory + incoming.updateHistory
        )
        return merged
    }

    static func normalizeObservations(_ observations: [Observation]) -> [Observation] {
        let historyNormalized = observations.map { observation in
            var updated = observation
            updated.historyEvents = normalizeObservationHistoryEventsAppendOnly(observation.historyEvents)
            updated.updateHistory = normalizeObservationUpdateEntriesAppendOnly(observation.updateHistory)
            return updated
        }
        return applyResolvedObservationPrecedence(historyNormalized)
    }

    private static func applyResolvedObservationPrecedence(_ observations: [Observation]) -> [Observation] {
        let latestResolvedByKey = observations.reduce(into: [String: Observation]()) { partial, observation in
            guard observation.status == .resolved,
                  let key = observationLocationIdentityKey(observation) else {
                return
            }
            guard let existing = partial[key],
                  observation.updatedAt <= existing.updatedAt else {
                partial[key] = observation
                return
            }
        }

        guard !latestResolvedByKey.isEmpty else { return observations }

        return observations.map { observation in
            guard observation.status == .active,
                  let key = observationLocationIdentityKey(observation),
                  let resolved = latestResolvedByKey[key],
                  resolved.updatedAt >= observation.updatedAt else {
                return observation
            }

            var suppressed = observation
            suppressed.status = .resolved
            suppressed.updatedAt = max(observation.updatedAt, resolved.updatedAt)
            suppressed.resolvedInSessionID = resolved.resolvedInSessionID ?? observation.resolvedInSessionID
            suppressed.resolutionPhotoRef = resolved.resolutionPhotoRef ?? observation.resolutionPhotoRef
            suppressed.resolutionStatement = resolved.resolutionStatement ?? observation.resolutionStatement
            return suppressed
        }
    }

    private static func observationLocationIdentityKey(_ observation: Observation) -> String? {
        let normalizedBuilding = normalizedGuidedPart(observation.building)
        let normalizedElevation = normalizedGuidedPart(CanonicalElevation.normalize(observation.targetElevation) ?? observation.targetElevation)
        let normalizedDetail = normalizedGuidedPart(observation.detailType)
        guard !normalizedBuilding.isEmpty,
              !normalizedElevation.isEmpty,
              !normalizedDetail.isEmpty else {
            return nil
        }
        return [normalizedBuilding, normalizedElevation, normalizedDetail].joined(separator: "|")
    }

    static func normalizeObservationHistoryEventsAppendOnly(
        _ events: [ObservationHistoryEvent]
    ) -> [ObservationHistoryEvent] {
        var latestByID: [UUID: ObservationHistoryEvent] = [:]
        var orderedIDs: [UUID] = []

        for event in events {
            if latestByID[event.id] == nil {
                orderedIDs.append(event.id)
            }
            latestByID[event.id] = event
        }

        return orderedIDs
            .compactMap { latestByID[$0] }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    static func normalizeObservationUpdateEntriesAppendOnly(
        _ entries: [ObservationUpdateEntry]
    ) -> [ObservationUpdateEntry] {
        var latestByID: [UUID: ObservationUpdateEntry] = [:]
        var orderedIDs: [UUID] = []

        for entry in entries {
            if latestByID[entry.id] == nil {
                orderedIDs.append(entry.id)
            }
            latestByID[entry.id] = entry
        }

        return orderedIDs
            .compactMap { latestByID[$0] }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}
