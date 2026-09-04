import Foundation

enum LocalConflictRules {
    // 2C-11 is intentionally a local deterministic conflict layer only.
    // Session lock ownership and any `locked_*` fields remain delegated to the
    // existing 2C-10b session coordination helpers and must not be routed
    // through these generic reducers.
    struct ActiveFlaggedGuidedSuppressionEvidence: Equatable {
        var shotIDs: Set<UUID>
        var imageIdentifiers: Set<String>
        var guidedKeys: Set<String>
        var guidedBaseKeys: Set<String>
        var guidedBaseKeyCutoffs: [String: Date]

        init(
            shotIDs: Set<UUID> = [],
            imageIdentifiers: Set<String> = [],
            guidedKeys: Set<String> = [],
            guidedBaseKeys: Set<String> = [],
            guidedBaseKeyCutoffs: [String: Date] = [:]
        ) {
            self.shotIDs = shotIDs
            self.imageIdentifiers = imageIdentifiers
            self.guidedKeys = guidedKeys
            self.guidedBaseKeys = guidedBaseKeys
            self.guidedBaseKeyCutoffs = guidedBaseKeyCutoffs
        }

        var isEmpty: Bool {
            shotIDs.isEmpty && imageIdentifiers.isEmpty && guidedKeys.isEmpty && guidedBaseKeys.isEmpty && guidedBaseKeyCutoffs.isEmpty
        }

        func merged(with other: ActiveFlaggedGuidedSuppressionEvidence) -> ActiveFlaggedGuidedSuppressionEvidence {
            var mergedCutoffs = guidedBaseKeyCutoffs
            for (key, cutoff) in other.guidedBaseKeyCutoffs {
                if let existing = mergedCutoffs[key] {
                    mergedCutoffs[key] = max(existing, cutoff)
                } else {
                    mergedCutoffs[key] = cutoff
                }
            }
            return ActiveFlaggedGuidedSuppressionEvidence(
                shotIDs: shotIDs.union(other.shotIDs),
                imageIdentifiers: imageIdentifiers.union(other.imageIdentifiers),
                guidedKeys: guidedKeys.union(other.guidedKeys),
                guidedBaseKeys: guidedBaseKeys.union(other.guidedBaseKeys),
                guidedBaseKeyCutoffs: mergedCutoffs
            )
        }
    }

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

    static func currentIssueShotSortPrecedes(
        _ lhs: ShotMetadata,
        _ rhs: ShotMetadata,
        linkedShotID: UUID?
    ) -> Bool {
        let lhsIsLinked = linkedShotID.map { lhs.shotID == $0 } ?? false
        let rhsIsLinked = linkedShotID.map { rhs.shotID == $0 } ?? false
        if lhsIsLinked != rhsIsLinked {
            return lhsIsLinked
        }

        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }

        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }

        if lhs.isFlagged != rhs.isFlagged {
            return lhs.isFlagged
        }

        return lhs.shotID.uuidString < rhs.shotID.uuidString
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

    static func guidedShotBaseIdentityKey(_ guidedShot: GuidedShot) -> String? {
        guidedShotBaseIdentityKey(
            building: guidedShot.building,
            elevation: guidedShot.targetElevation,
            detailType: guidedShot.detailType
        )
    }

    static func guidedShotBaseIdentityKey(
        building: String?,
        elevation: String?,
        detailType: String?
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
            normalizedDetail
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

    nonisolated static func shotMetadataIsOrdinaryGuidedWork(_ shot: ShotMetadata) -> Bool {
        guard shot.isGuided else { return false }
        if shot.isFlagged || shot.issueID != nil {
            return false
        }
        let issueStatus = trimmedNonEmpty(shot.issueStatus)?.lowercased()
        if issueStatus == "active" || issueStatus == "resolved" {
            return false
        }
        let captureKind = trimmedNonEmpty(shot.captureKind)?.lowercased()
        if captureKind == "resolved_capture" ||
            captureKind == "follow_up_capture" ||
            captureKind == "reference" ||
            captureKind == "reclassified" {
            return false
        }
        return true
    }

    static func issueLinkedShotIsCurrentSessionCapture(
        linkedShotID: UUID?,
        updatedInSessionID: UUID?,
        resolvedInSessionID: UUID?,
        currentSessionID: UUID?,
        currentSessionShotIDs: Set<UUID>
    ) -> Bool {
        guard let currentSessionID,
              let linkedShotID,
              currentSessionShotIDs.contains(linkedShotID) else {
            return false
        }
        return updatedInSessionID == currentSessionID || resolvedInSessionID == currentSessionID
    }

    static func activeFlaggedGuidedSuppressionEvidence(
        observations: [Observation] = [],
        issueLinkedGuidedShots: [ShotMetadata] = []
    ) -> ActiveFlaggedGuidedSuppressionEvidence {
        flaggedGuidedPromotionEvidence(
            observations: observations,
            issueLinkedGuidedShots: issueLinkedGuidedShots,
            includeResolved: false
        )
    }

    static func flaggedGuidedPromotionEvidence(
        observations: [Observation] = [],
        issueLinkedGuidedShots: [ShotMetadata] = [],
        includeResolved: Bool
    ) -> ActiveFlaggedGuidedSuppressionEvidence {
        let eligibleObservations = observations.filter { observation in
            observation.status == .active || (includeResolved && observation.status == .resolved)
        }
        let observationEvidence = eligibleObservations.reduce(into: ActiveFlaggedGuidedSuppressionEvidence()) { partial, observation in
            partial.shotIDs.formUnion(observation.shots.map(\.id))
            if let linkedShotID = observation.linkedShotID {
                partial.shotIDs.insert(linkedShotID)
            }
            partial.shotIDs.formUnion(observation.guidedShots.map(\.id))
            partial.shotIDs.formUnion(observation.guidedShots.compactMap { $0.shot?.id })
            for shot in observation.shots {
                partial.imageIdentifiers.formUnion(imageIdentifierVariants(shot.imageLocalIdentifier))
            }
            for guided in observation.guidedShots {
                if let key = guidedShotIdentityKey(guided) {
                    partial.guidedKeys.insert(key)
                }
                if let baseKey = guidedShotBaseIdentityKey(guided) {
                    partial.guidedBaseKeys.insert(baseKey)
                    partial.guidedBaseKeyCutoffs[baseKey] = max(
                        partial.guidedBaseKeyCutoffs[baseKey] ?? .distantPast,
                        observation.createdAt
                    )
                }
                partial.imageIdentifiers.formUnion(imageIdentifierVariants(guided.shot?.imageLocalIdentifier))
                partial.imageIdentifiers.formUnion(imageIdentifierVariants(guided.referenceImagePath))
                partial.imageIdentifiers.formUnion(imageIdentifierVariants(guided.referenceImageLocalIdentifier))
            }
        }

        let metadataEvidence = issueLinkedGuidedShots
            .filter { metadataShotRepresentsFlaggedGuidedIssue($0, includeResolved: includeResolved) }
            .reduce(into: ActiveFlaggedGuidedSuppressionEvidence()) { partial, shot in
                partial.shotIDs.insert(shot.shotID)
                if let supersedesShotID = shot.supersedesShotID {
                    partial.shotIDs.insert(supersedesShotID)
                }
                if let supersededByShotID = shot.supersededByShotID {
                    partial.shotIDs.insert(supersededByShotID)
                }
                if let key = guidedShotIdentityKey(
                    building: shot.building,
                    elevation: shot.elevation,
                    detailType: shot.detailType,
                    angleIndex: shot.angleIndex
                ) {
                    partial.guidedKeys.insert(key)
                }
                if let baseKey = guidedShotBaseIdentityKey(
                    building: shot.building,
                    elevation: shot.elevation,
                    detailType: shot.detailType
                ) {
                    partial.guidedBaseKeys.insert(baseKey)
                    partial.guidedBaseKeyCutoffs[baseKey] = max(
                        partial.guidedBaseKeyCutoffs[baseKey] ?? .distantPast,
                        shot.createdAt
                    )
                }
                let shotKey = shot.shotKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !shotKey.isEmpty {
                    partial.guidedKeys.insert(shotKey)
                }
                partial.imageIdentifiers.formUnion(imageIdentifierVariants(shot.originalRelativePath))
                partial.imageIdentifiers.formUnion(imageIdentifierVariants(shot.stampedRelativePath))
                partial.imageIdentifiers.formUnion(imageIdentifierVariants(shot.originalFilename))
                partial.imageIdentifiers.formUnion(imageIdentifierVariants(shot.stampedFilename))
                partial.imageIdentifiers.formUnion(imageIdentifierVariants(shot.storagePath))
            }

        return observationEvidence.merged(with: metadataEvidence)
    }

    static func retiredGuidedShotIsRestorable(
        _ guidedShot: GuidedShot,
        promotionEvidence: ActiveFlaggedGuidedSuppressionEvidence,
        retiredGuidedShots: [GuidedShot]
    ) -> Bool {
        guard guidedShot.isRetired || guidedShot.status == .retired else { return false }
        if promotionEvidence.isEmpty { return true }
        if promotionEvidence.shotIDs.contains(guidedShot.id) { return false }
        if let shotID = guidedShot.shot?.id,
           promotionEvidence.shotIDs.contains(shotID) {
            return false
        }
        if let key = guidedShotIdentityKey(guidedShot),
           promotionEvidence.guidedKeys.contains(key) {
            return false
        }
        if let baseKey = guidedShotBaseIdentityKey(guidedShot),
           promotionEvidence.guidedBaseKeys.contains(baseKey) {
            guard guidedKnownStateAt(guidedShot) <= (promotionEvidence.guidedBaseKeyCutoffs[baseKey] ?? .distantPast) else {
                return true
            }
            let baseMatchCount = retiredGuidedShots.filter {
                ($0.isRetired || $0.status == .retired) &&
                    guidedShotBaseIdentityKey($0) == baseKey &&
                    guidedKnownStateAt($0) <= (promotionEvidence.guidedBaseKeyCutoffs[baseKey] ?? .distantPast)
            }.count
            if baseMatchCount == 1 {
                return false
            }
        }
        var imageIdentifiers = imageIdentifierVariants(guidedShot.shot?.imageLocalIdentifier)
        imageIdentifiers.formUnion(imageIdentifierVariants(guidedShot.referenceImagePath))
        imageIdentifiers.formUnion(imageIdentifierVariants(guidedShot.referenceImageLocalIdentifier))
        if imageIdentifiers.contains(where: { promotionEvidence.imageIdentifiers.contains($0) }) {
            return false
        }
        return true
    }

    static func suppressGuidedShotsRepresentedByActiveFlaggedObservations(
        _ guidedShots: [GuidedShot],
        observations: [Observation],
        evidence additionalEvidence: ActiveFlaggedGuidedSuppressionEvidence = ActiveFlaggedGuidedSuppressionEvidence()
    ) -> [GuidedShot] {
        let evidence = activeFlaggedGuidedSuppressionEvidence(observations: observations)
            .merged(with: additionalEvidence)
        guard !evidence.isEmpty else { return guidedShots }

        let activeBaseKeyCounts = guidedShots.reduce(into: [String: Int]()) { counts, guided in
            guard guided.status != .retired,
                  !guided.isRetired,
                  let baseKey = guidedShotBaseIdentityKey(guided) else {
                return
            }
            if let cutoff = evidence.guidedBaseKeyCutoffs[baseKey],
               guidedKnownStateAt(guided) > cutoff {
                return
            }
            counts[baseKey, default: 0] += 1
        }

        return guidedShots.filter { guided in
            if evidence.shotIDs.contains(guided.id) {
                return false
            }
            if let shotID = guided.shot?.id, evidence.shotIDs.contains(shotID) {
                return false
            }
            if let key = guidedShotIdentityKey(guided),
               evidence.guidedKeys.contains(key) {
                return false
            }
            if let baseKey = guidedShotBaseIdentityKey(guided),
               evidence.guidedBaseKeys.contains(baseKey),
               guidedKnownStateAt(guided) <= (evidence.guidedBaseKeyCutoffs[baseKey] ?? .distantPast),
               activeBaseKeyCounts[baseKey] == 1 {
                return false
            }
            var imageIdentifiers = imageIdentifierVariants(guided.shot?.imageLocalIdentifier)
            imageIdentifiers.formUnion(imageIdentifierVariants(guided.referenceImagePath))
            imageIdentifiers.formUnion(imageIdentifierVariants(guided.referenceImageLocalIdentifier))
            if imageIdentifiers.contains(where: { evidence.imageIdentifiers.contains($0) }) {
                return false
            }
            return true
        }
    }

    nonisolated static func metadataShotRepresentsFlaggedGuidedIssue(
        _ shot: ShotMetadata,
        includeResolved: Bool = false
    ) -> Bool {
        guard shot.isGuided, !shotMetadataIsOrdinaryGuidedWork(shot) else { return false }
        let issueStatus = trimmedNonEmpty(shot.issueStatus)?.lowercased()
        if issueStatus == "resolved" {
            return includeResolved && shot.issueID != nil
        }
        return shot.isFlagged || shot.issueID != nil || issueStatus == "active"
    }

    private static func imageIdentifierVariants(_ value: String?) -> Set<String> {
        guard let trimmed = trimmedNonEmpty(value) else { return [] }
        var variants: Set<String> = [trimmed.lowercased()]
        let filename = URL(fileURLWithPath: trimmed).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filename.isEmpty {
            variants.insert(filename.lowercased())
        }
        return variants
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

    private nonisolated static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func reconcileObservationStatus(
        current: Observation,
        incoming: Observation
    ) -> Observation {
        let terminalResolvedSupportingDocumentation =
            observationIsTerminalResolvedSupportingDocumentation(current)
        let incomingExplicitlyReopens = incoming.historyEvents.contains { event in
            event.kind == .reopened &&
                event.afterValue == Observation.Status.active.issueStatusValue
        }
        let incomingWins = incoming.updatedAt > current.updatedAt
        var merged = incomingWins ? incoming : current

        merged.updatedAt = max(current.updatedAt, incoming.updatedAt)
        if terminalResolvedSupportingDocumentation,
           incoming.status != .resolved,
           !incomingExplicitlyReopens {
            merged.status = .resolved
            merged.resolvedInSessionID = current.resolvedInSessionID
            merged.resolutionPhotoRef = current.resolutionPhotoRef
            merged.resolutionStatement = current.resolutionStatement
            merged.linkedShotID = current.linkedShotID
            merged.shots = current.shots
        } else {
            merged.status = incomingWins ? incoming.status : current.status
        }
        merged.historyEvents = normalizeObservationHistoryEventsAppendOnly(
            current.historyEvents + incoming.historyEvents
        )
        merged.updateHistory = normalizeObservationUpdateEntriesAppendOnly(
            current.updateHistory + incoming.updateHistory
        )
        return merged
    }

    private static func observationIsTerminalResolvedSupportingDocumentation(_ observation: Observation) -> Bool {
        guard observation.status == .resolved else { return false }
        return observation.historyEvents.contains { event in
            event.kind == .resolved &&
                event.beforeValue == Observation.Status.resolutionRequired.issueStatusValue &&
                event.afterValue == Observation.Status.resolved.issueStatusValue
        }
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
