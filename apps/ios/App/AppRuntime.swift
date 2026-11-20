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
            sessionStates: { sessionStore.state },
            versionGate: VersionGate(
                build: graph.configuration.build, fetchMinimum: { await graph.fetchMinimumBuild() }),
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

    /// The scene became active: lifecycle work plus a version check, side by side.
    func sceneBecameActive() {
        Task { await model.versionGate.check() }
        guard let lifecycle else { return }
        Task { await lifecycle.activate() }
    }

    /// The scene moved to the background: runs the flush inside a UIKit background task so it can finish.
    func sceneEnteredBackground() {
        guard let lifecycle else { return }
        let assertion = BackgroundAssertion()
        Task {
            await lifecycle.enterBackground()
            assertion.end()
        }
    }
}

/// A UIKit background task around the backgrounding flush. Ends once, on completion or expiry.
@MainActor
private final class BackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "sroka.flush") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
