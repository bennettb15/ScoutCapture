import Foundation

enum SessionLifecyclePolicy {
    static func isFinal(_ session: Session?) -> Bool {
        guard let session else { return false }
        return session.status == .completed ||
            session.endedAt != nil ||
            session.exportedAt != nil ||
            session.isSealed ||
            session.firstDeliveredAt != nil
    }

    static func metadataIsFinal(_ metadata: SessionMetadata) -> Bool {
        metadata.status == .completed ||
            metadata.endedAt != nil ||
            metadata.exportedAt != nil ||
            metadata.isSealed ||
            metadata.firstDeliveredAt != nil
    }

    static func materialContentCount(_ session: Session, localStore: LocalStore) -> Int {
        guard let metadata = try? localStore.loadSessionMetadata(propertyID: session.propertyID, sessionID: session.id) else {
            return 0
        }
        return metadata.shots.filter { shot in
            guard shot.lifecycleState.isActiveForDefaultWorkflows else { return false }
            if shot.createdAt < session.startedAt { return false }
            if let endedAt = session.endedAt, shot.createdAt > endedAt { return false }
            let trimmedCaptureKind = shot.captureKind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let captureKind = trimmedCaptureKind.isEmpty ? nil : trimmedCaptureKind.lowercased()
            if captureKind == "reference" ||
                captureKind == "reclassified" ||
                captureKind == "restored" ||
                captureKind == "historical" {
                return false
            }
            let originalRelative = shot.originalRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !originalRelative.isEmpty else { return false }
            return localStore.resolveSessionRelativeFileURL(
                propertyID: session.propertyID,
                sessionID: session.id,
                relativePath: originalRelative
            ) != nil
        }.count
    }
}
