import Foundation

enum FastLaneThumbnailSource {
    static func currentIssueShot(in shots: [Shot], linkedShotID: UUID?) -> Shot? {
        if let linkedShotID, let linked = shots.first(where: { $0.id == linkedShotID }) {
            return linked
        }
        return shots.max { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt < rhs.capturedAt }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    static func path(for currentShotPath: String, resolvedPath: String?) -> String {
        let resolved = resolvedPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !resolved.isEmpty,
           URL(fileURLWithPath: resolved).lastPathComponent.caseInsensitiveCompare(
            URL(fileURLWithPath: currentShotPath).lastPathComponent
           ) == .orderedSame {
            return resolved
        }
        return currentShotPath
    }
}
