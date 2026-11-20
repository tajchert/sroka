import SrokaLive
import SwiftUI

@main
struct SrokaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let runtime: AppRuntime
    /// The app-wide phase across all windows: one iPad window going to the background must not suspend the database
    /// while another is still active.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        runtime = AppComposition.prepare()
        AppDelegate.push = runtime.pushJobs
    }

    var body: some Scene {
        let jobs = runtime.backgroundJobs
        WindowGroup {
            AppRoot(runtime: runtime)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: runtime.appBecameActive()
            case .background: runtime.appEnteredBackground()
            default: break
            }
        }
        // SwiftUI registers both identifiers (Info.plist BGTaskSchedulerPermittedIdentifiers), completes each task
        // when its closure returns and cancels the closure when the system expires the task.
        .backgroundTask(.appRefresh(BackgroundTaskID.refresh)) {
            _ = await jobs?.refresh()
        }
        .backgroundTask(.processingTask(BackgroundTaskID.download)) {
            _ = await jobs?.download()
        }
    }
}
