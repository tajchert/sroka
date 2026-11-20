import Dependencies

/// Observable state of sync + downloads for progress UI (DECISIONS A9, A11). Android: SyncStatusRepository.kt.
public protocol SyncStatusRepository: Sendable {
    /// Current phase and counts; emits immediately.
    var status: AsyncStream<SyncStatus> { get }

    /// One-shot results of user-initiated fetches (hot; not replayed to late consumers).
    var events: AsyncStream<SyncEvent> { get }
}

private struct UnimplementedSyncStatusRepository: SyncStatusRepository {
    private func fail(_ method: String) {
        reportUnimplemented("SyncStatusRepository.\(method)", key: "syncStatusRepository")
    }

    var status: AsyncStream<SyncStatus> {
        fail("status")
        return .finished
    }
    var events: AsyncStream<SyncEvent> {
        fail("events")
        return .finished
    }
}

private enum SyncStatusRepositoryKey: TestDependencyKey {
    static let testValue: any SyncStatusRepository = UnimplementedSyncStatusRepository()
}

extension DependencyValues {
    public var syncStatusRepository: any SyncStatusRepository {
        get { self[SyncStatusRepositoryKey.self] }
        set { self[SyncStatusRepositoryKey.self] = newValue }
    }
}
