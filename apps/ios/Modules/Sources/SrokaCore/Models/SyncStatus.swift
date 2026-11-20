import Foundation

/// Combined state of background sync and article downloads (DECISIONS A9).
public struct SyncStatus: Sendable, Hashable {
    public var phase: SyncPhase
    /// Local changes not yet pushed to the server.
    public var pendingOps: Int
    /// Items whose article package is on the device.
    public var downloadedCount: Int
    /// Items eligible for offline reading (downloaded or still to download).
    public var availableCount: Int
    /// Last successful sync, or nil if never.
    public var lastSyncAt: Date?

    public init(
        phase: SyncPhase = .idle,
        pendingOps: Int = 0,
        downloadedCount: Int = 0,
        availableCount: Int = 0,
        lastSyncAt: Date? = nil
    ) {
        self.phase = phase
        self.pendingOps = pendingOps
        self.downloadedCount = downloadedCount
        self.availableCount = availableCount
        self.lastSyncAt = lastSyncAt
    }
}

public enum SyncPhase: Sendable, Hashable {
    case idle
    case syncing
    /// Downloading article packages: `done` of `total`, `currentTitle` being fetched.
    case downloading(done: Int, total: Int, currentTitle: String?)
    /// Full resync running (410 or a pass from cursor 0). `fraction` 0...1, or nil when unknown.
    case resyncing(fraction: Double?)
    /// No network; the app shows saved articles.
    case offline
    case error(SyncErrorKind)
}

public enum SyncErrorKind: String, Sendable, Hashable {
    /// Session expired (HTTP 401): the user must sign in again.
    case auth
    case network
    case server
    /// Not enough free device storage for article packages.
    case storage
}

/// One-shot results of user-initiated fetches.
public enum SyncEvent: Sendable, Hashable {
    /// A fetch finished. `newlyDownloaded == 0` means "Library is up to date".
    case fetchCompleted(newlyDownloaded: Int)
    /// A fetch stopped early.
    case fetchFailed(SyncErrorKind)
}
