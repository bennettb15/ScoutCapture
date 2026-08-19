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
        guidedShots.reduce(into: [GuidedShot]()) { partial, guidedShot in
            partial = applyGuidedCompletionState(current: partial, incoming: guidedShot)
        }
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
