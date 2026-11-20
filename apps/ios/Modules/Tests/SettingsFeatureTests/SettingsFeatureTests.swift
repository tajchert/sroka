import Clocks
import Dependencies
import Foundation
import SrokaCore
import SrokaTesting
import Testing

@testable import SettingsFeature

/// Lets observation tasks (which hop between executors) deliver their first values.
func settle() async {
    try? await ContinuousClock().sleep(for: .milliseconds(25))
    for _ in 0..<30 { await Task.yield() }
}

@MainActor
final class IntentLog {
    var intents: [SettingsIntent] = []
}

@MainActor
struct SettingsViewModelTests {
    private func harness(
        preferences: UserPreferences = UserPreferences(),
        session: SessionState = .signedIn(email: "reader@example.com")
    ) -> (SettingsViewModel, Fakes, TestClock<Duration>, IntentLog) {
        let fakes = Fakes(session: session, preferences: preferences)
        let clock = TestClock()
        let log = IntentLog()
        let model = withDependencies {
            $0.useFakes(fakes)
            $0.continuousClock = clock
        } operation: {
            SettingsViewModel(appVersion: "1.0 (7)") { intent in log.intents.append(intent) }
        }
        return (model, fakes, clock, log)
    }

    /// Runs `body` while the model observes the repositories.
    private func observing(_ model: SettingsViewModel, _ body: () async -> Void) async {
        let task = Task { await model.task() }
        await settle()
        await body()
        task.cancel()
    }

    // MARK: Loading

    @Test func `The form shows preferences, account, consent, storage and server`() async {
        let (model, fakes, _, _) = harness(preferences: UserPreferences(themeMode: .dark))
        fakes.consent.state.send(Consent(analytics: true, crashReports: false))
        await observing(model) {
            #expect(model.preferences.themeMode == .dark)
            #expect(model.email == "reader@example.com")
            #expect(model.consent == Consent(analytics: true, crashReports: false))
            #expect(model.storageBytes == 12_400_000)
            #expect(model.serverURL == "https://api.sroka.app")
        }
    }

    @Test func `A custom server replaces the default in the Server row`() async {
        let (model, _, _, _) = harness(preferences: UserPreferences(serverUrl: "https://sroka.example.com"))
        await observing(model) {
            #expect(model.serverURL == "https://sroka.example.com")
        }
    }

    @Test func `Signing out clears the email`() async {
        let (model, fakes, _, _) = harness()
        await observing(model) {
            fakes.auth.state.send(.signedOut)
            await settle()
            #expect(model.email == nil)
        }
    }

    @Test func `The version comes from the bundle info`() {
        #expect(
            SettingsViewModel.bundleVersion(["CFBundleShortVersionString": "1.5.0", "CFBundleVersion": "42"])
                == "1.5.0 (42)")
        #expect(SettingsViewModel.bundleVersion(["CFBundleShortVersionString": "1.5.0"]) == "1.5.0")
        #expect(SettingsViewModel.bundleVersion([:]) == "?")
    }

    // MARK: Writes

    @Test func `Each reading setting is written`() async {
        let (model, fakes, _, _) = harness()
        await model.themeSelected(.dark)
        await model.readerThemeSelected(.sepia)
        await model.textScaleSelected(1.3)
        let state = fakes.settings.state.value
        #expect(state.themeMode == .dark)
        #expect(state.readerTheme == .sepia)
        #expect(state.readerTextScale == 1.3)
    }

    @Test func `Each swipe action is written`() async {
        let (model, fakes, _, _) = harness()
        await model.swipeLeftSelected(.favorite)
        await model.swipeRightSelected(.tags)
        #expect(fakes.settings.state.value.swipeLeftAction == .favorite)
        #expect(fakes.settings.state.value.swipeRightAction == .tags)
    }

    @Test func `The download policy is written`() async {
        let (model, fakes, _, _) = harness()
        await model.downloadPolicySelected(.manual)
        #expect(fakes.settings.state.value.downloadPolicy == .manual)
    }

    @Test func `The privacy switches write consent`() async {
        let (model, fakes, _, _) = harness()
        await model.analyticsToggled(true)
        await model.crashReportsToggled(false)
        #expect(fakes.consent.state.value == Consent(analytics: true, crashReports: false))
    }

    @Test func `The text size picker snaps to the nearest step`() async {
        let (model, _, _, _) = harness(preferences: UserPreferences(readerTextScale: 1.2))
        await observing(model) {
            #expect(model.nearestTextScaleStep == 1.15)
        }
        #expect(SettingsViewModel.textPoints(scale: 1.0) == 18)
        #expect(SettingsViewModel.textPoints(scale: 1.6) == 29)
    }

    // MARK: Library

    @Test func `Download all now fetches and says so for a few seconds`() async {
        let (model, fakes, clock, _) = harness()
        model.downloadAllNowTapped()
        #expect(fakes.syncController.calls.calls == [.fetchNewArticles])
        #expect(model.message != nil)
        await settle()
        await clock.advance(by: .seconds(SettingsViewModel.messageSeconds))
        await settle()
        #expect(model.message == nil)
    }

    @Test func `Removing downloads asks first and then clears them`() async {
        let (model, fakes, _, _) = harness()
        await observing(model) {
            model.removeDownloadsTapped()
            #expect(model.isConfirmingRemoveDownloads)
            #expect(fakes.content.calls.calls.isEmpty)
            await model.removeDownloadsConfirmed()
            #expect(fakes.content.calls.calls == ["clearDownloads"])
            #expect(model.storageBytes == 0)
            #expect(model.message != nil)
        }
    }

    // MARK: Account

    @Test func `Signing out asks first, then signs out and leaves settings`() async {
        let (model, fakes, _, log) = harness()
        model.signOutTapped()
        #expect(model.isConfirmingSignOut)
        #expect(fakes.auth.calls.calls.isEmpty)
        #expect(log.intents.isEmpty)
        await model.signOutConfirmed()
        #expect(fakes.auth.calls.calls == ["signOut"])
        #expect(log.intents == [.signedOut])
        #expect(!model.isBusy)
    }

    @Test func `Delete needs the email typed exactly, ignoring case and spaces`() {
        #expect(SettingsViewModel.isDeleteConfirmed(typed: "reader@example.com", email: "reader@example.com"))
        #expect(SettingsViewModel.isDeleteConfirmed(typed: "  Reader@Example.COM ", email: "reader@example.com"))
        #expect(!SettingsViewModel.isDeleteConfirmed(typed: "reader@example", email: "reader@example.com"))
        #expect(!SettingsViewModel.isDeleteConfirmed(typed: "", email: "reader@example.com"))
        #expect(!SettingsViewModel.isDeleteConfirmed(typed: "", email: ""))
        #expect(!SettingsViewModel.isDeleteConfirmed(typed: "reader@example.com", email: nil))
    }

    @Test func `Delete does nothing until the email is typed`() async {
        let (model, fakes, _, log) = harness()
        await observing(model) {
            model.deleteAccountTapped()
            #expect(model.isConfirmingDeleteAccount)
            #expect(model.deleteConfirmationText.isEmpty)
            model.deleteConfirmationText = "someone@else.com"
            #expect(!model.isDeleteConfirmed)
            await model.deleteAccountConfirmed()
            #expect(fakes.account.calls.calls.isEmpty)
            #expect(log.intents.isEmpty)
        }
    }

    @Test func `Delete with the email typed deletes and signs out`() async {
        let (model, fakes, _, log) = harness()
        await observing(model) {
            model.deleteAccountTapped()
            model.deleteConfirmationText = "Reader@example.com"
            await model.deleteAccountConfirmed()
            #expect(fakes.account.calls.calls == ["deleteAccount"])
            #expect(log.intents == [.signedOut])
        }
    }

    @Test func `A failed delete stays in settings and says so`() async {
        let (model, fakes, _, log) = harness()
        fakes.account.deleteResult.send(.failed(.network))
        await observing(model) {
            model.deleteAccountTapped()
            model.deleteConfirmationText = "reader@example.com"
            await model.deleteAccountConfirmed()
            #expect(log.intents.isEmpty)
            #expect(model.message != nil)
            #expect(!model.isBusy)
        }
    }

    // MARK: Navigation

    @Test func `Rows push their screens`() {
        let (model, _, _, _) = harness()
        model.serverTapped()
        model.exportTapped()
        model.importTapped()
        #expect(model.path == [.server, .export, .import])
    }

    @Test func `Done dismisses the sheet`() async {
        let (model, _, _, log) = harness()
        await model.doneTapped()
        #expect(log.intents == [.dismissed])
    }

    @Test func `Switching server pops to the root and signs out`() async {
        let (model, _, _, log) = harness()
        model.serverTapped()
        await model.serverSwitched()
        #expect(model.path.isEmpty)
        #expect(log.intents == [.signedOut])
    }

    // MARK: Server screen

    @Test func `Saving a valid server screen entry stores it without switching when unchanged`() async {
        let fakes = Fakes()
        var outcomes: [ServerSettingsViewModel.Outcome] = []
        let model = withDependencies {
            $0.useFakes(fakes)
        } operation: {
            ServerSettingsViewModel(currentServer: "https://api.sroka.app") { outcomes.append($0) }
        }
        #expect(!model.isSwitching)
        await model.saveTapped()
        #expect(outcomes == [.saved])
    }

    @Test func `Pointing at another server is a switch and says so`() async {
        let fakes = Fakes()
        var outcomes: [ServerSettingsViewModel.Outcome] = []
        let model = withDependencies {
            $0.useFakes(fakes)
        } operation: {
            ServerSettingsViewModel(currentServer: "https://api.sroka.app") { outcomes.append($0) }
        }
        model.text = "https://sroka.example.com/"
        #expect(model.isSwitching)
        await model.saveTapped()
        #expect(outcomes == [.switched])
        #expect(fakes.settings.state.value.serverUrl == "https://sroka.example.com/")
    }

    @Test func `A blank entry goes back to the default server`() async {
        let fakes = Fakes(preferences: UserPreferences(serverUrl: "https://sroka.example.com"))
        var outcomes: [ServerSettingsViewModel.Outcome] = []
        let model = withDependencies {
            $0.useFakes(fakes)
        } operation: {
            ServerSettingsViewModel(currentServer: "https://sroka.example.com") { outcomes.append($0) }
        }
        model.text = "  "
        #expect(model.isSwitching)
        await model.saveTapped()
        #expect(fakes.settings.state.value.serverUrl == nil)
        #expect(outcomes == [.switched])
    }

    @Test func `An invalid server is flagged and not saved`() async {
        let fakes = Fakes()
        var outcomes: [ServerSettingsViewModel.Outcome] = []
        let model = withDependencies {
            $0.useFakes(fakes)
        } operation: {
            ServerSettingsViewModel(currentServer: "https://api.sroka.app") { outcomes.append($0) }
        }
        model.text = "http://sroka.example.com"
        await model.saveTapped()
        #expect(model.isInvalid)
        #expect(outcomes.isEmpty)
        model.text = "https://sroka.example.com"
        #expect(!model.isInvalid)
    }
}
