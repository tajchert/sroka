import Dependencies
import Foundation
import SrokaCore
import SrokaDesign
import SrokaLive
import SrokaTesting

/// The composition root: the ONE place that decides which concrete implementations back the app's
/// dependencies. Feature modules never know which implementation they get.
///
/// Normal launches build the live graph (`LiveGraph`: database in the App Group, network, session, sync, content).
/// `-UITests` keeps the in-memory fakes from SrokaTesting so UI tests stay fast and deterministic.
enum AppComposition {
    @MainActor
    static func prepare() -> AppRuntime {
        SrokaFont.registerFonts()
        let environment = DependencyValues._current.appEnvironment
        if ProcessInfo.processInfo.arguments.contains("-UITests") {
            let fakes = Fakes()
            prepareDependencies { $0.useFakes(fakes) }
            return AppRuntime.fakes(fakes, scheme: environment.urlScheme)
        }
        let info = Bundle.main.infoDictionary ?? [:]
        // `makeTelemetry()` is the bare SDK. The graph wraps it in `ConsentGatedTelemetry` (registered as
        // `\.telemetry`) and starts `ConsentApplier` with the gated value in `install`; until the stored consent is
        // applied the SDK collects nothing (Info.plist defaults are off).
        let graph = LiveGraph(
            configuration: LiveConfiguration(
                environment: environment,
                appVersion: info["CFBundleShortVersionString"] as? String ?? "0",
                build: buildNumber(fromBundleVersion: info["CFBundleVersion"] as? String),
                appIdentifierPrefix: info["AppIdentifierPrefix"] as? String,
                telemetry: makeTelemetry()))
        prepareDependencies { graph.install(into: &$0) }
        return AppRuntime.live(graph)
    }
}
