import Foundation
import SrokaCore

/// The work the app does when its scene becomes active or moves to the background, as closures over the live graph
/// (tests pass recorders).
public struct LifecycleActions: Sendable {
    /// Database: foreground (resume) and background (suspend once nothing holds it).
    public var enterForeground: @Sendable () -> Void
    public var enterBackground: @Sendable () -> Void
    /// Keeps the database running until the returned closure is called.
    public var holdDatabase: @Sendable () -> @Sendable () -> Void
    /// Re-reads the Keychain session and the App Group preferences (the share extension may have changed them).
    public var reloadStores: @Sendable () -> Void
    /// Tells database observers about rows the share extension wrote.
    public var notifyExternalChanges: @Sendable () async -> Void
    public var isSignedIn: @Sendable () -> Bool
    public var recoverInterrupted: @Sendable () async -> Void
    public var resumePendingUploads: @Sendable () -> Void
    public var resumeImport: @Sendable () -> Void
    public var requestSync: @Sendable () -> Void
    public var pendingOpCount: @Sendable () async -> Int
    /// Pushes queued ops before the app is suspended.
    public var syncNow: @Sendable () async -> Void
    public var cancelAutomaticDownloads: @Sendable () -> Void
    /// Automatic downloads may start (foreground) or must be deferred to the background task (background).
    public var setDownloadsForeground: @Sendable (Bool) -> Void
    public var scheduleRefresh: @Sendable () -> Void
    /// True when the policy allows automatic downloads and eligible items wait.
    public var needsBackgroundDownload: @Sendable () async -> Bool
    public var scheduleDownload: @Sendable () -> Void
    /// UIKit background time ran out: suspend the database whatever still holds it.
    public var expireBackground: @Sendable () -> Void

    public init(
        enterForeground: @escaping @Sendable () -> Void,
        enterBackground: @escaping @Sendable () -> Void,
        holdDatabase: @escaping @Sendable () -> @Sendable () -> Void,
        reloadStores: @escaping @Sendable () -> Void,
        notifyExternalChanges: @escaping @Sendable () async -> Void,
        isSignedIn: @escaping @Sendable () -> Bool,
        recoverInterrupted: @escaping @Sendable () async -> Void,
        resumePendingUploads: @escaping @Sendable () -> Void,
        resumeImport: @escaping @Sendable () -> Void,
        requestSync: @escaping @Sendable () -> Void,
        pendingOpCount: @escaping @Sendable () async -> Int,
        syncNow: @escaping @Sendable () async -> Void,
        cancelAutomaticDownloads: @escaping @Sendable () -> Void,
        setDownloadsForeground: @escaping @Sendable (Bool) -> Void,
        scheduleRefresh: @escaping @Sendable () -> Void,
        needsBackgroundDownload: @escaping @Sendable () async -> Bool,
        scheduleDownload: @escaping @Sendable () -> Void,
        expireBackground: @escaping @Sendable () -> Void = {}
    ) {
        self.enterForeground = enterForeground
        self.enterBackground = enterBackground
        self.holdDatabase = holdDatabase
        self.reloadStores = reloadStores
        self.notifyExternalChanges = notifyExternalChanges
        self.isSignedIn = isSignedIn
        self.recoverInterrupted = recoverInterrupted
        self.resumePendingUploads = resumePendingUploads
        self.resumeImport = resumeImport
        self.requestSync = requestSync
        self.pendingOpCount = pendingOpCount
        self.syncNow = syncNow
        self.cancelAutomaticDownloads = cancelAutomaticDownloads
        self.setDownloadsForeground = setDownloadsForeground
        self.scheduleRefresh = scheduleRefresh
        self.needsBackgroundDownload = needsBackgroundDownload
        self.scheduleDownload = scheduleDownload
        self.expireBackground = expireBackground
    }
}

/// Runs scene activation and backgrounding in a fixed order. The synchronous part of each transition (database
/// resume or suspend, download foreground flag) runs at the call, on the main actor, so quick back-and-forth
/// transitions apply in the order the scene reported them.
@MainActor
public final class AppLifecycle {
    private let actions: LifecycleActions
    /// Bumped by every transition; activation work stops after an await once a newer transition superseded it.
    private var transition = 0

    public init(actions: LifecycleActions) {
        self.actions = actions
    }

    /// The scene became active: resume the database, reload what the share extension may have changed, then (signed in
    /// only) recover interrupted downloads, resume uploads and import polling, and sync.
    public func activate() async {
        let actions = actions
        transition += 1
        let current = transition
        actions.enterForeground()
        actions.setDownloadsForeground(true)
        actions.reloadStores()
        await actions.notifyExternalChanges()
        guard transition == current, actions.isSignedIn() else { return }
        await actions.recoverInterrupted()
        guard transition == current, actions.isSignedIn() else { return }
        actions.resumePendingUploads()
        actions.resumeImport()
        actions.requestSync()
    }

    /// The scene moved to the background: stop foreground downloads, push queued ops while the database is held,
    /// schedule the background refresh and download tasks, then let the database suspend. Call inside a UIKit
    /// background task so the push can finish.
    public func enterBackground() async {
        await flush(beginBackground())
    }

    /// One backgrounding: its transition id and the database hold its flush releases.
    public struct BackgroundFlush: Sendable {
        public let transition: Int
        fileprivate let release: @Sendable () -> Void
    }

    /// The synchronous part of backgrounding, at the call: hold the database, stop foreground downloads, mark the
    /// database background. Pass the result to `flush(_:)`, and to `backgroundExpired(_:)` if the time runs out.
    public func beginBackground() -> BackgroundFlush {
        transition += 1
        let release = actions.holdDatabase()
        actions.setDownloadsForeground(false)
        actions.cancelAutomaticDownloads()
        actions.enterBackground()
        return BackgroundFlush(transition: transition, release: release)
    }

    /// The background time of `background` ran out: suspend the database now, unless a newer transition (the app came
    /// back, or backgrounded again with its own background time) has taken over since.
    public func backgroundExpired(_ background: BackgroundFlush) {
        guard transition == background.transition else { return }
        actions.expireBackground()
    }

    /// The rest of backgrounding: push queued ops, schedule the background tasks, then release the hold.
    public func flush(_ background: BackgroundFlush) async {
        let actions = actions
        defer { background.release() }
        guard actions.isSignedIn() else { return }
        if await actions.pendingOpCount() > 0 {
            await actions.syncNow()
        }
        actions.scheduleRefresh()
        if await actions.needsBackgroundDownload() {
            actions.scheduleDownload()
        }
    }
}
