import Foundation
import SrokaCore
import SrokaLive
import SrokaTesting
import UIKit

/// Process-wide app state the root view needs: `AppModel` (session, version gate, pending deep link) and the scene
/// lifecycle. Created once by `AppComposition.prepare()`.
@MainActor
final class AppRuntime {
    let model: AppModel
    /// Background task work; nil under `-UITests`, where the tasks do nothing.
    nonisolated let backgroundJobs: BackgroundJobs?
    private let lifecycle: AppLifecycle?

    private init(model: AppModel, lifecycle: AppLifecycle?, backgroundJobs: BackgroundJobs?) {
        self.model = model
        self.lifecycle = lifecycle
        self.backgroundJobs = backgroundJobs
    }

    static func live(_ graph: LiveGraph) -> AppRuntime {
        let sessionStore = graph.sessionStore
        let model = AppModel(
            sessionStates: { sessionStore.state }, serverChanges: { graph.serverChanges() },
            versionGate: VersionGate(
                build: graph.configuration.build, server: { graph.currentServer() },
                fetchMinimum: { await graph.fetchMinimumBuild() }),
            deepLinks: DeepLinkInbox(scheme: graph.configuration.environment.urlScheme))
        return AppRuntime(
            model: model, lifecycle: AppLifecycle(actions: graph.lifecycleActions()),
            backgroundJobs: graph.backgroundJobs())
    }

    static func fakes(_ fakes: Fakes, scheme: String) -> AppRuntime {
        let auth = fakes.auth
        let model = AppModel(
            sessionStates: { auth.session }, versionGate: .alwaysSupported(),
            deepLinks: DeepLinkInbox(scheme: scheme))
        return AppRuntime(model: model, lifecycle: nil, backgroundJobs: nil)
    }

    func start() {
        model.start()
    }

    /// The app became active: lifecycle work plus a version check, side by side.
    func appBecameActive() {
        Task { await model.versionGate.check() }
        guard let lifecycle else { return }
        Task { await lifecycle.activate() }
    }

    /// The app moved to the background: runs the flush inside a UIKit background task so it can finish. If the time
    /// runs out first, that flush is cancelled and, unless the app came back or backgrounded again since, the
    /// database is suspended before the task ends.
    func appEnteredBackground() {
        guard let lifecycle else { return }
        let background = lifecycle.beginBackground()
        let assertion = BackgroundAssertion { lifecycle.backgroundExpired(background) }
        assertion.flush = Task {
            await lifecycle.flush(background)
            assertion.end()
        }
    }
}

/// A UIKit background task around one backgrounding flush. Ends once, on completion or expiry; on expiry it cancels
/// its own flush (never a newer one) and runs `onExpiry` first.
@MainActor
private final class BackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    var flush: Task<Void, Never>?

    init(onExpiry: @escaping @MainActor () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "sroka.flush") { [weak self] in
            MainActor.assumeIsolated {
                self?.flush?.cancel()
                onExpiry()
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
