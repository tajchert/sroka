import AppNavigation
import Foundation
import SettingsFeature
import SrokaTesting

/// Screenshot and UI-test aid: `-UITests -UITestsRoute <name>` lands the app on one screen without tapping.
/// Only honoured together with `-UITests` (the app's fakes), never in a normal launch.
///
/// Names: `myList`, `archive`, `tags`, `search`, `settings`, `reader`, `tagEditor`, `signInAgain`.
@MainActor
enum DebugRoute {
    static func applyIfRequested(
        to router: AppRouter, consent: ConsentPromptViewModel,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) async {
        guard arguments.contains("-UITests"),
            let index = arguments.firstIndex(of: "-UITestsRoute"),
            arguments.indices.contains(index + 1)
        else { return }
        // A requested route is a screenshot or UI test: the first-run consent prompt would cover it.
        await consent.declineTapped()
        let itemId = Fixtures.longRead.id
        switch arguments[index + 1] {
        case "myList": router.select(.myList)
        case "archive": router.select(.archive)
        case "tags": router.select(.tags)
        case "search": router.select(.search)
        case "settings": router.presentSettings()
        case "reader": router.open(itemId: itemId)
        case "tagEditor": router.presentTagEditor(itemId: itemId)
        case "signInAgain": router.presentSignInAgain()
        default: break
        }
    }
}
