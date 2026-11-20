import SrokaLive
import SwiftUI

@main
struct SrokaApp: App {
    private let runtime: AppRuntime

    init() {
        runtime = AppComposition.prepare()
    }

    var body: some Scene {
        let jobs = runtime.backgroundJobs
        WindowGroup {
            AppRoot(runtime: runtime)
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
