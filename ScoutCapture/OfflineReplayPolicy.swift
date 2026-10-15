import Foundation

enum OfflineReplayPolicy {
    static func backoffInterval(forAttemptCount attemptCount: Int) -> TimeInterval {
        switch attemptCount {
        case ...0:
            return 0
        case 1:
            return 30
        case 2:
            return 120
        case 3:
            return 600
        default:
            return 1800
        }
    }

    static func automaticAttemptLimit(for source: String, launchLimit: Int) -> Int? {
        source.hasPrefix("launch") ? launchLimit : nil
    }

    static func shouldReplay(_ mutation: LocalStore.QueuedMutation, now: Date) -> Bool {
        if mutation.isAcknowledgedHistoricalDebt {
            return false
        }
        switch mutation.status {
        case .pending:
            return true
        case .failed:
            return retryIsDue(nextAttemptAt: mutation.nextAttemptAt, now: now)
        case .inFlight, .completed:
            return false
        }
    }

    static func shouldReplaySnapshotUpload(
        _ item: LocalStore.SessionSnapshotUploadRetryWorkItem,
        now: Date
    ) -> Bool {
        switch item.status {
        case .pending:
            return true
        case .failed:
            return retryIsDue(nextAttemptAt: item.nextAttemptAt, now: now)
        case .inFlight, .terminalFailed:
            return false
        }
    }

    private static func retryIsDue(nextAttemptAt: Date?, now: Date) -> Bool {
        nextAttemptAt.map { now >= $0 } ?? true
    }
}
