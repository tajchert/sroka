import BackgroundTasks
import Foundation

/// `BGTaskScheduler` identifiers. Each one is listed in the app's Info.plist `BGTaskSchedulerPermittedIdentifiers`.
public enum BackgroundTaskID {
    /// `BGAppRefreshTask`: a sync pass (`SyncScheduler.handleBackgroundRefresh`).
    public static let refresh = "app.sroka.refresh"
    /// `BGProcessingTask`: automatic article downloads under the download policy.
    public static let download = "app.sroka.download"
}

/// Submits and cancels background task requests.
public protocol BackgroundScheduling: Sendable {
    func scheduleRefresh()
    func scheduleDownload()
    /// Sign-out: nothing scheduled for the old account may run.
    func cancelAll()
}

/// `BGTaskScheduler.shared`. Submitting replaces an earlier request with the same identifier.
public struct SystemBackgroundScheduler: BackgroundScheduling {
    /// Earliest start of the next refresh after it is scheduled.
    public var refreshInterval: TimeInterval

    public init(refreshInterval: TimeInterval = 60 * 60) {
        self.refreshInterval = refreshInterval
    }

    public func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskID.refresh)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        submit(request)
    }

    public func scheduleDownload() {
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskID.download)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        submit(request)
    }

    public func cancelAll() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }

    private func submit(_ request: BGTaskRequest) {
        BGTaskScheduler.shared.submitTaskRequest(request) { error in
            // Simulator, Background App Refresh off, or too many pending requests: the next foreground sync covers it.
            if let error {
                liveLog.notice("Background task not scheduled: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// A background scheduler that does nothing (UI tests, previews, missing App Group).
public struct NoBackgroundScheduler: BackgroundScheduling {
    public init() {}
    public func scheduleRefresh() {}
    public func scheduleDownload() {}
    public func cancelAll() {}
}

/// The work each background task runs, attached with SwiftUI's `.backgroundTask(.appRefresh(_:))` and
/// `.backgroundTask(.processingTask(_:))` (SwiftUI registers the identifiers, completes the task when the closure
/// returns and cancels it when the system expires the task). Each stops early when cancelled.
public struct BackgroundJobs: Sendable {
    public var refresh: @Sendable () async -> Bool
    public var download: @Sendable () async -> Bool

    public init(refresh: @escaping @Sendable () async -> Bool, download: @escaping @Sendable () async -> Bool) {
        self.refresh = refresh
        self.download = download
    }
}
