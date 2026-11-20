import Foundation
import SrokaCore

// What the sync layer needs from other streams. Each is a small protocol the composition root fills
// with the live implementation (session: stream I; content: stream H) or with the no-op defaults below.

/// The signed-in session as the sync engine sees it (stream I implements it).
public protocol SyncSession: Sendable {
    /// Current state. A pass runs only while `.signedIn`.
    func currentState() async -> SessionState

    /// The state now, then every change (new stream per call).
    func observeState() -> AsyncStream<SessionState>

    /// The server answered 401: keep every local row and the token's owner, show "Sign in again".
    func markExpired() async
}

/// Progress of a bulk article download, for the Downloading status card.
public struct SyncDownloadProgress: Sendable, Hashable {
    public var done: Int
    public var total: Int
    public var currentTitle: String?

    public init(done: Int, total: Int, currentTitle: String? = nil) {
        self.done = done
        self.total = total
        self.currentTitle = currentTitle
    }
}

/// Offline-content work the sync layer starts (stream H implements it; Android `ContentStoreImpl`,
/// `ContentPaths`, `WorkScheduler` download parts). Every method must return quickly: long work
/// (downloads) runs in the content layer's own tasks. Hooks never throw; failures are the content
/// layer's to log.
public protocol SyncContentHooks: Sendable {
    /// Deletes the article package, thumbnail and temporary files of items that no longer exist
    /// locally. Called after the transaction that removed them has committed.
    func deleteItemFiles(itemIds: [String]) async

    /// After a successful background sync: queue downloads of eligible items per the download
    /// policy (Wi-Fi only / any network / manual = nothing).
    func queueAutomaticDownloads() async

    /// After every successful sync: drop packages of long-archived items (A9 eviction).
    func evict() async

    /// User "Fetch new articles", after its sync succeeded: download every eligible item now,
    /// ignoring Wi-Fi only, and report `.fetchCompleted(newlyDownloaded:)` or `.fetchFailed(_:)`.
    func fetchDownloads() async -> SyncEvent

    /// One item's package now, any network (reader).
    func downloadItemNow(itemId: String) async

    /// The running bulk download (nil when none), current value first.
    func observeDownloadProgress() -> AsyncStream<SyncDownloadProgress?>
}

/// Whether the device has a usable network path, current value first.
public protocol NetworkStatus: Sendable {
    func observeOnline() -> AsyncStream<Bool>
}

/// Content hooks that do nothing (share extension, tests, or before stream H is wired).
public struct NoContentHooks: SyncContentHooks {
    public init() {}

    public func deleteItemFiles(itemIds: [String]) async {}
    public func queueAutomaticDownloads() async {}
    public func evict() async {}
    public func fetchDownloads() async -> SyncEvent { .fetchCompleted(newlyDownloaded: 0) }
    public func downloadItemNow(itemId: String) async {}
    public func observeDownloadProgress() -> AsyncStream<SyncDownloadProgress?> { .just(nil) }
}

/// A network status that is always online (tests, previews).
public struct AlwaysOnline: NetworkStatus {
    public init() {}

    public func observeOnline() -> AsyncStream<Bool> { .just(true) }
}
