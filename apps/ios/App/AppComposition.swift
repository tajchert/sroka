import Dependencies
import Foundation
import SrokaDesign
import SrokaTesting

/// The composition root: the ONE place that decides which concrete implementations back the app's
/// dependencies. Feature modules never know which implementation they get.
///
/// Until the live engine lands (streams A, B, G, H, I), every build runs on the in-memory fakes from
/// SrokaTesting. Swap them here, keeping `-UITests` on fakes so UI tests stay fast and deterministic.
enum AppComposition {
    static func prepare() {
        SrokaFont.registerFonts()
        prepareDependencies { dependencies in
            if ProcessInfo.processInfo.arguments.contains("-UITests") {
                dependencies.useFakes(Fakes())
            } else {
                // TODO(streams G/H/I): live repositories in this environment's App Group
                // (dependencies.appEnvironment.appGroupIdentifier).
                dependencies.useFakes(Fakes())
                dependencies.telemetry = makeTelemetry()
            }
        }
    }
}
