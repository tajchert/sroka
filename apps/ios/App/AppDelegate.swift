import OSLog
import SrokaLive
import UIKit

private let pushLog = Logger(subsystem: "app.sroka", category: "push")

/// The UIKit hooks SwiftUI has no scene API for: the APNs device token and the silent "sync" push (D17).
///
/// The app never requests alert permission: a background push (`content-available`) needs none.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by `SrokaApp.init`, which runs before any delegate callback; nil under `-UITests`.
    @MainActor static var push: PushJobs?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        if Self.push != nil { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.push?.deviceTokenReceived(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Simulator without APNs, no network, or a profile without the push capability: periodic sync covers it.
        pushLog.notice("Remote notification registration failed: \(String(describing: error), privacy: .public)")
    }

    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard SyncPushMessage.isSync(userInfo), let push = Self.push else { return .noData }
        let foreground = application.applicationState == .active
        pushLog.info("Sync push received (foreground: \(foreground, privacy: .public))")
        let result = await push.syncRequested(foreground)
        pushLog.info("Sync push handled: \(String(describing: result), privacy: .public)")
        switch result {
        case .newData: return .newData
        case .noData: return .noData
        case .failed: return .failed
        }
    }
}
