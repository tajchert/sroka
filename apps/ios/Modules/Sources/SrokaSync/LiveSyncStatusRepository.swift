import Foundation
import SrokaCore
import SrokaDatabase
import Synchronization

/// `SyncStatus` from the running pass, `sync_state`, counts, connectivity, session and download
/// progress (DECISIONS A9/A11). Android: `SyncStatusRepositoryImpl`.
public struct LiveSyncStatusRepository: SyncStatusRepository {
    private let database: AppDatabase
    private let scheduler: SyncScheduler
    private let session: any SyncSession
    private let hooks: any SyncContentHooks
    private let network: any NetworkStatus

    public init(
        database: AppDatabase,
        scheduler: SyncScheduler,
        session: any SyncSession,
        hooks: any SyncContentHooks = NoContentHooks(),
        network: any NetworkStatus = AlwaysOnline()
    ) {
        self.database = database
        self.scheduler = scheduler
        self.session = session
        self.hooks = hooks
        self.network = network
    }

    /// Emits once every source has produced a value, then on every change (duplicates dropped).
    public var status: AsyncStream<SyncStatus> {
        let database = database
        let scheduler = scheduler
        let session = session
        let hooks = hooks
        let network = network
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let combiner = StatusCombiner(continuation)
            let tasks = [
                combiner.feed(scheduler.observeRunning()) { $0.syncing = $1 },
                combiner.feed(AsyncStream.observing { database.observeSyncState() }) { $0.state = $1 },
                combiner.feed(AsyncStream.observing { database.observePendingOpCount() }) { $0.pending = $1 },
                combiner.feed(AsyncStream.observing { database.observeDownloadedCount() }) { $0.downloaded = $1 },
                combiner.feed(AsyncStream.observing { database.observeEligibleDownloadCount() }) {
                    $0.available = $1
                },
                combiner.feed(network.observeOnline()) { $0.online = $1 },
                combiner.feed(session.observeState()) { inputs, state in
                    if case .expired = state { inputs.expired = true } else { inputs.expired = false }
                },
                combiner.feed(hooks.observeDownloadProgress()) { $0.download = .some($1) },
            ]
            continuation.onTermination = { _ in
                for task in tasks { task.cancel() }
            }
        }
    }

    public var events: AsyncStream<SyncEvent> { scheduler.events }

    /// Android `SyncStatusRepositoryImpl.phaseOf`, same priority order.
    static func phaseOf(
        syncing: Bool,
        downloading: SyncDownloadProgress?,
        state: SyncStateRecord,
        online: Bool,
        expired: Bool
    ) -> SyncPhase {
        if expired { return .error(.auth) }
        // A full pass (410 or from cursor 0) is flagged in sync_state; the pull response carries no
        // total (api.md §7.2), so the fraction is unknown.
        if syncing, state.fullResync { return .resyncing(fraction: nil) }
        if syncing { return .syncing }
        if let downloading {
            return .downloading(
                done: downloading.done, total: downloading.total, currentTitle: downloading.currentTitle)
        }
        if !online { return .offline }
        // A network error while the device reports connectivity is transient; do not alarm.
        if let kind = state.lastError.flatMap(SyncErrorKind.init(rawValue:)), kind != .network { return .error(kind) }
        return .idle
    }
}

/// The latest value of each source; a status exists once all are set.
private struct StatusInputs {
    var syncing: Bool?
    var state: SyncStateRecord?
    var pending: Int?
    var downloaded: Int?
    var available: Int?
    var online: Bool?
    var expired: Bool?
    var download: SyncDownloadProgress??

    var status: SyncStatus? {
        guard let syncing, let state, let pending, let downloaded, let available, let online, let expired,
            let download
        else { return nil }
        return SyncStatus(
            phase: LiveSyncStatusRepository.phaseOf(
                syncing: syncing, downloading: download, state: state, online: online, expired: expired),
            pendingOps: pending,
            downloadedCount: downloaded,
            availableCount: available,
            lastSyncAt: state.lastSuccessAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        )
    }
}

private final class StatusCombiner: Sendable {
    private struct State {
        var inputs = StatusInputs()
        var last: SyncStatus?
    }

    private let state = Mutex(State())
    private let continuation: AsyncStream<SyncStatus>.Continuation

    init(_ continuation: AsyncStream<SyncStatus>.Continuation) { self.continuation = continuation }

    func feed<Element: Sendable>(
        _ source: AsyncStream<Element>,
        _ apply: @escaping @Sendable (inout StatusInputs, Element) -> Void
    ) -> Task<Void, Never> {
        Task {
            for await value in source { update { apply(&$0, value) } }
        }
    }

    private func update(_ change: (inout StatusInputs) -> Void) {
        state.withLock { state in
            change(&state.inputs)
            guard let status = state.inputs.status, status != state.last else { return }
            state.last = status
            continuation.yield(status)
        }
    }
}
