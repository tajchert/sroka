import Clocks
import Dependencies
import SrokaCore
import SrokaTesting
import Testing

@testable import AuthFeature

private func settle() async {
    for _ in 0..<30 { await Task.yield() }
}

@MainActor
private final class IntentLog {
    var intents: [AuthIntent] = []
}

@MainActor
struct AuthViewModelTests {
    private func harness(session: SessionState = .signedOut) -> (AuthViewModel, Fakes, TestClock<Duration>, IntentLog) {
        let fakes = Fakes(session: session)
        let clock = TestClock()
        let log = IntentLog()
        let model = withDependencies {
            $0.useFakes(fakes)
            $0.continuousClock = clock
        } operation: {
            AuthViewModel { intent in log.intents.append(intent) }
        }
        return (model, fakes, clock, log)
    }

    private func reachCodeStep(_ model: AuthViewModel) async {
        model.email = "reader@example.com"
        await model.sendCodeTapped()
    }

    // MARK: Email

    @Test func `Valid and invalid emails`() {
        #expect(AuthViewModel.isValidEmail("a@b.co"))
        #expect(AuthViewModel.isValidEmail("first.last+tag@sub.example.org"))
        #expect(!AuthViewModel.isValidEmail(""))
        #expect(!AuthViewModel.isValidEmail("no-at.example.com"))
        #expect(!AuthViewModel.isValidEmail("a@b"))
        #expect(!AuthViewModel.isValidEmail("a b@c.de"))
        #expect(!AuthViewModel.isValidEmail("a@@c.de"))
        let long = String(repeating: "a", count: 250) + "@b.co"
        #expect(!AuthViewModel.isValidEmail(long))
        let limit = String(repeating: "a", count: 254 - 5) + "@b.co"
        #expect(AuthViewModel.isValidEmail(limit))
    }

    @Test func `An invalid email shows an error and sends nothing`() async {
        let (model, fakes, _, _) = harness()
        model.email = "nope"
        await model.sendCodeTapped()
        #expect(model.error == .invalidEmail)
        #expect(model.step == .email)
        #expect(fakes.auth.calls.calls.isEmpty)
        #expect(model.failureCount == 1)
    }

    @Test func `Editing the email clears the error`() async {
        let (model, _, _, _) = harness()
        model.email = "nope"
        await model.sendCodeTapped()
        model.email = "nope@"
        #expect(model.error == nil)
    }

    @Test func `A valid email moves to the code step and starts the cooldown`() async {
        let (model, fakes, _, _) = harness()
        model.email = "  reader@example.com  "
        await model.sendCodeTapped()
        #expect(model.step == .code)
        #expect(model.email == "reader@example.com")
        #expect(model.resendSeconds == AuthViewModel.resendCooldownSeconds)
        #expect(fakes.auth.calls.calls == ["sendCode"])
        #expect(!model.isLoading)
    }

    @Test func `A failed send shows the repository error and stays on the email step`() async {
        let (model, fakes, _, _) = harness()
        fakes.auth.forcedFailure.send(.rateLimited(retryAfterSeconds: 30))
        model.email = "reader@example.com"
        await model.sendCodeTapped()
        #expect(model.step == .email)
        #expect(model.error == .rateLimited(retryAfterSeconds: 30))
    }

    // MARK: Code

    @Test func `The sixth digit submits and signs in`() async {
        let (model, fakes, _, log) = harness()
        await reachCodeStep(model)
        await model.codeChanged("12345")
        #expect(fakes.auth.calls.calls == ["sendCode"])
        await model.codeChanged("123456")
        #expect(fakes.auth.calls.calls == ["sendCode", "signIn"])
        #expect(log.intents == [.signedIn])
        #expect(fakes.telemetry.events.calls == [.login])
        #expect(fakes.auth.state.value == .signedIn(email: "reader@example.com"))
    }

    @Test func `Whitespace and letters are stripped and extra digits dropped`() async {
        let (model, fakes, _, log) = harness()
        await reachCodeStep(model)
        await model.codeChanged("12 34\t56 78")
        #expect(model.code == "123456")
        #expect(log.intents == [.signedIn])
        #expect(fakes.auth.calls.calls.filter { $0 == "signIn" }.count == 1)
    }

    @Test func `A wrong code shows the error and clears the field`() async {
        let (model, _, _, log) = harness()
        await reachCodeStep(model)
        await model.codeChanged("000000")
        #expect(model.error == .invalidCode)
        #expect(model.code.isEmpty)
        #expect(model.failureCount == 1)
        #expect(log.intents.isEmpty)
        #expect(model.step == .code)
    }

    @Test(
        arguments: [
            (AuthError.invalidCode, "That code is not correct. Try again."),
            (.codeExpired, "That code has expired. Request a new one."),
            (.tooManyAttempts, "Too many attempts. Request a new code."),
            (.rateLimited(retryAfterSeconds: nil), "Too many requests. Please wait a moment and try again."),
            (.rateLimited(retryAfterSeconds: 42), "Too many requests. Try again in 42 seconds."),
            (.network, "You appear to be offline. Check your connection and try again."),
            (.server, "The server could not complete the request. Try again later."),
        ]
    )
    func `Each submit error maps to its sentence`(error: AuthError, sentence: String) async {
        let (model, fakes, _, log) = harness()
        await reachCodeStep(model)
        fakes.auth.forcedFailure.send(error)
        await model.codeChanged("123456")
        #expect(model.error == error)
        #expect(model.errorMessage.map { String(localized: $0) } == sentence)
        #expect(log.intents.isEmpty)
    }

    @Test func `A network failure keeps the typed code`() async {
        let (model, fakes, _, _) = harness()
        await reachCodeStep(model)
        fakes.auth.forcedFailure.send(.network)
        await model.codeChanged("123456")
        #expect(model.code == "123456")
    }

    @Test func `Typing again clears the error`() async {
        let (model, _, _, _) = harness()
        await reachCodeStep(model)
        await model.codeChanged("000000")
        #expect(model.error != nil)
        await model.codeChanged("1")
        #expect(model.error == nil)
    }

    // MARK: Resend

    @Test func `The resend countdown ticks down to zero`() async {
        let (model, _, clock, _) = harness()
        await reachCodeStep(model)
        await settle()
        #expect(model.resendSeconds == 60)
        await clock.advance(by: .seconds(1))
        await settle()
        #expect(model.resendSeconds == 59)
        await clock.advance(by: .seconds(59))
        await settle()
        #expect(model.resendSeconds == 0)
    }

    @Test func `Resend is ignored during the cooldown and works after it`() async {
        let (model, fakes, clock, _) = harness()
        await reachCodeStep(model)
        await settle()
        await model.resendTapped()
        #expect(fakes.auth.calls.calls == ["sendCode"])
        await clock.advance(by: .seconds(60))
        await settle()
        #expect(model.resendSeconds == 0)
        await model.resendTapped()
        #expect(fakes.auth.calls.calls == ["sendCode", "sendCode"])
        #expect(model.resendSeconds == 60)
    }

    @Test func `A rate limited resend uses the server's retry time as the cooldown`() async {
        let (model, fakes, clock, _) = harness()
        await reachCodeStep(model)
        await settle()
        await clock.advance(by: .seconds(60))
        await settle()
        fakes.auth.forcedFailure.send(.rateLimited(retryAfterSeconds: 25))
        await model.resendTapped()
        #expect(model.error == .rateLimited(retryAfterSeconds: 25))
        #expect(model.resendSeconds == 25)
    }

    @Test func `Back returns to the email step and resets the code step`() async {
        let (model, _, _, _) = harness()
        await reachCodeStep(model)
        await model.codeChanged("000000")
        model.useAnotherEmailTapped()
        #expect(model.step == .email)
        #expect(model.code.isEmpty)
        #expect(model.error == nil)
        #expect(model.resendSeconds == 0)
    }

    // MARK: Sign in again

    @Test func `An expired session prefills the email and explains why`() async {
        let (model, _, _, _) = harness(session: .expired(email: "reader@example.com"))
        await model.task()
        #expect(model.isSigningInAgain)
        #expect(model.email == "reader@example.com")
    }

    @Test func `A signed out session leaves the email empty`() async {
        let (model, _, _, _) = harness()
        await model.task()
        #expect(!model.isSigningInAgain)
        #expect(model.email.isEmpty)
    }

    // MARK: Server

    @Test(
        arguments: [
            ("", true),
            ("https://sroka.example.com", true),
            ("https://sroka.example.com/", true),
            ("https://sroka.example.com:8443/api", true),
            ("http://localhost:8787", true),
            ("http://127.0.0.1:8787", true),
            ("http://sroka.example.com", false),
            ("ftp://sroka.example.com", false),
            ("https://sroka.example.com?x=1", false),
            ("https://sroka.example.com#frag", false),
            ("https://user:pass@sroka.example.com", false),
            ("https://user@sroka.example.com", false),
            ("sroka.example.com", false),
            ("https://", false),
        ]
    )
    func `Server URL validation`(input: String, expected: Bool) {
        #expect(ServerURLInput.isValid(input) == expected)
    }

    @Test func `Saving a valid server stores it and closes the sheet`() async {
        let (model, fakes, _, _) = harness()
        await model.selfHostingTapped()
        #expect(model.isShowingServerSheet)
        #expect(model.serverURLText == "https://api.sroka.app")
        model.serverURLText = "https://sroka.example.com"
        await model.saveServerTapped()
        #expect(!model.isShowingServerSheet)
        #expect(fakes.settings.state.value.serverUrl == "https://sroka.example.com")
        #expect(model.customServerHost == "sroka.example.com")
    }

    @Test func `Saving an invalid server keeps the sheet open and flags it`() async {
        let (model, fakes, _, _) = harness()
        await model.selfHostingTapped()
        model.serverURLText = "http://sroka.example.com"
        await model.saveServerTapped()
        #expect(model.isShowingServerSheet)
        #expect(model.isServerURLInvalid)
        #expect(fakes.settings.state.value.serverUrl == nil)
        model.serverURLEdited()
        #expect(!model.isServerURLInvalid)
    }

    @Test func `Saving an empty server restores the default`() async {
        let (model, fakes, _, _) = harness()
        fakes.settings.state.update { $0.serverUrl = "https://sroka.example.com" }
        await model.selfHostingTapped()
        model.serverURLText = ""
        await model.saveServerTapped()
        #expect(fakes.settings.state.value.serverUrl == nil)
        #expect(model.customServerHost == nil)
    }

    @Test func `A stored custom server shows its host`() async {
        let (model, fakes, _, _) = harness()
        fakes.settings.state.update { $0.serverUrl = "https://sroka.example.com/api" }
        await model.task()
        #expect(model.customServerHost == "sroka.example.com")
    }
}
