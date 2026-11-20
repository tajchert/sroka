import Dependencies

/// Starts background work (DECISIONS A8/A9). All calls are fire-and-forget and safe to call
/// repeatedly; progress and results are observed through `SyncStatusRepository`. Android: SyncController.kt.
public protocol SyncController: Sendable {
    /// Background sync (push + pull), e.g. on scene active. Honors the download policy afterwards.
    func requestSync()

    /// User-initiated "Fetch new articles" / pull to refresh: sync, then download all eligible
    /// articles, ignoring Wi-Fi only. Completion arrives as a `SyncEvent`.
    func fetchNewArticles()

    /// Queues a download of one item's package with high priority (any network).
    func downloadItemNow(itemId: String)
}

private struct UnimplementedSyncController: SyncController {
    private func fail(_ method: String) { reportUnimplemented("SyncController.\(method)", key: "syncController") }

    func requestSync() { fail("requestSync") }
    func fetchNewArticles() { fail("fetchNewArticles") }
    func downloadItemNow(itemId: String) { fail("downloadItemNow") }
}

private enum SyncControllerKey: TestDependencyKey {
    static let testValue: any SyncController = UnimplementedSyncController()
}

extension DependencyValues {
    public var syncController: any SyncController {
        get { self[SyncControllerKey.self] }
        set { self[SyncControllerKey.self] = newValue }
    }
}
