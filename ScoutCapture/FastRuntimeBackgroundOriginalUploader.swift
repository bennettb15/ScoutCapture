import Foundation

/// Queues file-backed transfers with iOS so photos can continue uploading while
/// the capture app is suspended. Results are durable because the app may be
/// relaunched between a Storage response and its shot-row acknowledgement.
final class FastRuntimeBackgroundOriginalUploader: NSObject, URLSessionTaskDelegate {
    static let shared = FastRuntimeBackgroundOriginalUploader()
    static let sessionIdentifier = "com.scoutsystems.scoutcapture.originals.background"

    struct Upload: Sendable {
        let sessionID: UUID
        let shotID: UUID
        let checksumSHA256: String
        let endpoint: URL
        let fileURL: URL
        let contentType: String
        let accessToken: String
        let anonKey: String

        var key: String {
            "\(sessionID.uuidString.lowercased()):\(shotID.uuidString.lowercased()):\(checksumSHA256):\(endpoint.absoluteString)"
        }
    }

    struct Outcome: Codable, Sendable {
        let succeeded: Bool
        let statusCode: Int?
        let message: String?
    }

    private let lock = NSLock()
    private var waiters: [String: [CheckedContinuation<Outcome, Never>]] = [:]
    private var backgroundEventsCompletionHandler: (() -> Void)?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        _ = session
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundEventsCompletionHandler = completionHandler
        lock.unlock()
        _ = session
    }

    /// Scheduling the whole batch allows iOS to finish it even after the app
    /// itself is suspended. Existing tasks are reused after a system relaunch.
    func enqueue(_ uploads: [Upload]) async {
        let existingTasks = await session.allTasks
        var existingKeys = Set(existingTasks.compactMap(\.taskDescription))
        for upload in uploads where !existingKeys.contains(upload.key) {
            if cachedOutcome(for: upload.key)?.succeeded == true { continue }
            clearOutcome(for: upload.key)
            var request = URLRequest(url: upload.endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(upload.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(upload.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("true", forHTTPHeaderField: "x-upsert")
            request.setValue("31536000", forHTTPHeaderField: "cache-control")
            request.setValue(upload.contentType, forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: request, fromFile: upload.fileURL)
            task.taskDescription = upload.key
            task.resume()
            existingKeys.insert(upload.key)
        }
    }

    func outcome(for key: String) async -> Outcome {
        if let outcome = cachedOutcome(for: key) { return outcome }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome = cachedOutcome(for: key) {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                waiters[key, default: []].append(continuation)
                lock.unlock()
            }
        }
    }

    func clearOutcome(for key: String) {
        UserDefaults.standard.removeObject(forKey: outcomeKey(key))
    }

    private func cachedOutcome(for key: String) -> Outcome? {
        guard let data = UserDefaults.standard.data(forKey: outcomeKey(key)) else { return nil }
        return try? JSONDecoder().decode(Outcome.self, from: data)
    }

    private func outcomeKey(_ key: String) -> String {
        "scoutcapture.background-original-upload.\(key)"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        let succeeded = error == nil && (statusCode.map { (200...299).contains($0) } ?? false)
        let outcome = Outcome(
            succeeded: succeeded,
            statusCode: statusCode,
            message: error?.localizedDescription ?? (succeeded ? nil : "Photo upload returned HTTP \(statusCode ?? 0).")
        )
        if let data = try? JSONEncoder().encode(outcome) {
            UserDefaults.standard.set(data, forKey: outcomeKey(key))
        }
        lock.lock()
        let pending = waiters.removeValue(forKey: key) ?? []
        lock.unlock()
        pending.forEach { $0.resume(returning: outcome) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        lock.unlock()
        if let completion {
            DispatchQueue.main.async(execute: completion)
        }
    }
}
