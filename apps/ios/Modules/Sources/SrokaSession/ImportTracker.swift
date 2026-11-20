import Foundation
import SrokaCore
import SrokaNetwork
import Synchronization

/// Result of one `GET /v1/imports/{id}` poll.
public enum PollOutcome: Sendable, Equatable {
    case updated(ImportJob)
    /// Connectivity or 5xx: try again later.
    case transient
    /// Signed out (401) or the job is no longer the stored one: stop polling.
    case stop
}

/// How a polling loop ended.
public enum PollEnd: Sendable, Equatable {
    case finished
    case stopped
    case tooManyErrors
}

/// Polls an import job every 3 s while it is queued or running and mirrors it into `ImportJobStore`. Polling runs
/// while the app runs; the stored job id lets `resumeIfNeeded()` pick it up again on the next launch. Android:
/// ImportProgressWorker.kt and ImportTracker.kt (the notification and sync request are `onFinished`).
public final class ImportTracker: Sendable {
    /// Error code stored when the server no longer knows the job (404).
    public static let errorLost = "lost"
    public static let pollInterval: Duration = .seconds(3)
    public static let maxConsecutiveErrors = 40

    private let api: any SrokaAPI
    private let store: ImportJobStore
    private let sessionStore: SessionStore
    private let clock: any Clock<Duration>
    private let onFinished: @Sendable (ImportJob) -> Void
    private let running = Mutex<(id: String, task: Task<Void, Never>)?>(nil)

    /// `onFinished` runs once per job that reaches done/failed while polled (local notification, sync request).
    public init(
        api: any SrokaAPI,
        store: ImportJobStore,
        sessionStore: SessionStore,
        clock: any Clock<Duration>,
        onFinished: @escaping @Sendable (ImportJob) -> Void
    ) {
        self.api = api
        self.store = store
        self.sessionStore = sessionStore
        self.clock = clock
        self.onFinished = onFinished
    }

    /// True while a polling loop runs (tests).
    public var isTracking: Bool { running.withLock { $0 != nil } }

    /// Starts polling `jobId` unless it is already being polled. A different job replaces the running loop.
    public func track(jobId: String) {
        running.withLock { running in
            if running?.id == jobId { return }
            running?.task.cancel()
            let task = Task { [weak self] in
                guard let self else { return }
                _ = await self.poll(jobId: jobId)
                self.running.withLock { if $0?.id == jobId { $0 = nil } }
            }
            running = (jobId, task)
        }
    }

    /// Call at launch: resumes polling for a stored job that has not finished.
    public func resumeIfNeeded() {
        guard let job = store.current, !job.status.isFinished else { return }
        track(jobId: job.id)
    }

    public func stop() {
        running.withLock { running in
            running?.task.cancel()
            running = nil
        }
    }

    /// Polls until the job finishes, polling is told to stop, too many transient errors happen in a row, or the task
    /// is cancelled.
    func poll(jobId: String) async -> PollEnd {
        var errors = 0
        while !Task.isCancelled {
            switch await refresh(jobId: jobId) {
            case .updated(let job):
                errors = 0
                if job.status.isFinished {
                    onFinished(job)
                    return .finished
                }
            case .transient:
                errors += 1
                if errors >= Self.maxConsecutiveErrors { return .tooManyErrors }
            case .stop:
                return .stopped
            }
            do {
                try await clock.sleep(for: Self.pollInterval)
            } catch {
                return .stopped
            }
        }
        return .stopped
    }

    /// One poll.
    public func refresh(jobId: String) async -> PollOutcome {
        guard let known = store.current, known.id == jobId else { return .stop }
        switch await apiCall({ try await api.importJob(id: jobId) }) {
        case .success(let dto):
            let job = dto.importJob(fallbackFormat: known.format)
            return store.update(job) ? .updated(job) : .stop
        case .failure(let error):
            switch error.status {
            case 401:
                sessionStore.markExpired()
                return .stop
            case 404:
                // The server no longer knows the job: record a terminal state so the UI is never stuck.
                var lost = known
                lost.status = .failed
                lost.error = Self.errorLost
                return store.update(lost) ? .updated(lost) : .stop
            default:
                return Task.isCancelled ? .stop : .transient
            }
        }
    }
}
