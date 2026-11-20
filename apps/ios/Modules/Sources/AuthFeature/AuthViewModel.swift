import Dependencies
import Foundation
import Observation
import SrokaCore

/// What the app root must do when the sign-in screen finishes.
public enum AuthIntent: Sendable, Hashable {
    /// The code was accepted and the session is stored: leave the sign-in screen.
    case signedIn
}

/// Email, then 6-digit code (Android `AuthViewModel`). Also the "sign in again" screen: an expired
/// session prefills the email.
@Observable @MainActor
public final class AuthViewModel {
    public enum Step: Sendable, Hashable { case email, code }

    public static let codeLength = 6
    public static let resendCooldownSeconds = 60
    public static let maxEmailLength = 254

    public private(set) var step: Step = .email
    /// Bound to the email field; editing clears a shown error.
    public var email = "" {
        didSet {
            if oldValue != email, error != nil { error = nil }
        }
    }
    /// Bound to the code field; the view forwards every change to `codeChanged(_:)`.
    public var code = ""
    public private(set) var isLoading = false
    public private(set) var error: AuthError?
    public private(set) var resendSeconds = 0
    /// The session expired: same screen, email prefilled, copy explains why.
    public private(set) var isSigningInAgain = false
    /// Increments on every failed attempt; the view shakes the cells and plays a haptic on change.
    public private(set) var failureCount = 0

    // Server sheet ("Self-hosting?").
    public var isShowingServerSheet = false
    public var serverURLText = ""
    public private(set) var isServerURLInvalid = false
    /// Host of a custom server, shown next to "Self-hosting?".
    public private(set) var customServerHost: String?

    @ObservationIgnored public var onIntent: (AuthIntent) async -> Void

    @ObservationIgnored @Dependency(\.authRepository) private var auth
    @ObservationIgnored @Dependency(\.settingsRepository) private var settings
    @ObservationIgnored @Dependency(\.telemetry) private var telemetry
    @ObservationIgnored @Dependency(\.continuousClock) private var clock
    @ObservationIgnored private var cooldownTask: Task<Void, Never>?

    public init(onIntent: @escaping (AuthIntent) async -> Void = { _ in }) {
        self.onIntent = onIntent
    }

    isolated deinit { cooldownTask?.cancel() }

    // MARK: Loading

    /// Reads the stored session (prefill after expiry) and the custom server.
    public func task() async {
        if case .expired(let expiredEmail) = await auth.session.firstValue() {
            isSigningInAgain = true
            if email.isEmpty { email = expiredEmail }
        }
        if let custom = await settings.preferences.firstValue()?.serverUrl {
            customServerHost = ServerURLInput.host(of: custom) ?? custom
        }
    }

    // MARK: Email step

    public func sendCodeTapped() async {
        guard !isLoading else { return }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidEmail(trimmed) else {
            fail(.invalidEmail)
            return
        }
        email = trimmed
        isLoading = true
        let result = await auth.sendCode(email: trimmed)
        isLoading = false
        handleSend(result, isResend: false)
    }

    // MARK: Code step

    /// The code field changed: keep six digits (whitespace and anything else stripped) and submit
    /// when the sixth arrives.
    public func codeChanged(_ value: String) async {
        let digits = String(value.filter(\.isASCIIDigit).prefix(Self.codeLength))
        guard !isLoading else {
            if code != digits { code = digits }
            return
        }
        if code != digits { code = digits }
        if error != nil { error = nil }
        if digits.count == Self.codeLength { await submitCode() }
    }

    public func resendTapped() async {
        guard !isLoading, resendSeconds == 0 else { return }
        isLoading = true
        error = nil
        code = ""
        let result = await auth.sendCode(email: email)
        isLoading = false
        handleSend(result, isResend: true)
    }

    /// Back from the code step.
    public func useAnotherEmailTapped() {
        cooldownTask?.cancel()
        step = .email
        code = ""
        error = nil
        resendSeconds = 0
    }

    // MARK: Server sheet

    public func selfHostingTapped() async {
        let preferences = await settings.preferences.firstValue()
        serverURLText = preferences?.serverUrl ?? settings.defaultServerUrl
        isServerURLInvalid = false
        isShowingServerSheet = true
    }

    public func serverURLEdited() {
        if isServerURLInvalid { isServerURLInvalid = false }
    }

    /// Saves the custom server; empty restores the default.
    public func saveServerTapped() async {
        let url = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ServerURLInput.isValid(url) else {
            isServerURLInvalid = true
            return
        }
        guard await settings.setServerUrl(url.isEmpty ? nil : url) else {
            isServerURLInvalid = true
            return
        }
        customServerHost = url.isEmpty ? nil : (ServerURLInput.host(of: url) ?? url)
        isServerURLInvalid = false
        isShowingServerSheet = false
    }

    public func cancelServerTapped() {
        isShowingServerSheet = false
        isServerURLInvalid = false
    }

    // MARK: Messages

    public var errorMessage: LocalizedStringResource? {
        guard let error else { return nil }
        switch error {
        case .invalidEmail:
            return LocalizedStringResource("Enter a valid email address.", bundle: #bundle)
        case .invalidCode:
            return LocalizedStringResource("That code is not correct. Try again.", bundle: #bundle)
        case .codeExpired:
            return LocalizedStringResource("That code has expired. Request a new one.", bundle: #bundle)
        case .tooManyAttempts:
            return LocalizedStringResource("Too many attempts. Request a new code.", bundle: #bundle)
        case .rateLimited(let seconds):
            guard let seconds, seconds > 0 else {
                return LocalizedStringResource(
                    "Too many requests. Please wait a moment and try again.",
                    bundle: #bundle
                )
            }
            return LocalizedStringResource(
                "Too many requests. Try again in \(seconds) seconds.",
                bundle: #bundle,
                comment: "Rate limit; the number is whole seconds"
            )
        case .network:
            return LocalizedStringResource(
                "You appear to be offline. Check your connection and try again.",
                bundle: #bundle
            )
        case .server:
            return LocalizedStringResource(
                "The server could not complete the request. Try again later.",
                bundle: #bundle
            )
        }
    }

    // MARK: Validation

    /// `^[^\s@]+@[^\s@]+\.[^\s@]+$`, at most 254 characters (plan "Email validation").
    public static func isValidEmail(_ email: String) -> Bool {
        email.count <= maxEmailLength && email.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) != nil
    }

    // MARK: Private

    private func submitCode() async {
        guard !isLoading, code.count == Self.codeLength else { return }
        isLoading = true
        error = nil
        let result = await auth.signIn(email: email, code: code)
        isLoading = false
        switch result {
        case .success:
            telemetry.logEvent(.login)
            await onIntent(.signedIn)
        case .failure(let failure):
            fail(failure)
            // A wrong or dead code is cleared; a network or server failure keeps what was typed.
            if failure != .network && failure != .server { code = "" }
        }
    }

    private func handleSend(_ result: AuthResult, isResend: Bool) {
        switch result {
        case .success:
            step = .code
            code = ""
            startCooldown(Self.resendCooldownSeconds)
        case .failure(let failure):
            fail(failure)
            if isResend, case .rateLimited(let seconds) = failure {
                startCooldown(seconds ?? Self.resendCooldownSeconds)
            }
        }
    }

    private func fail(_ failure: AuthError) {
        error = failure
        failureCount += 1
    }

    private func startCooldown(_ seconds: Int) {
        cooldownTask?.cancel()
        resendSeconds = seconds
        cooldownTask = Task { [clock] in
            var left = seconds
            while left > 0 {
                do { try await clock.sleep(for: .seconds(1)) } catch { return }
                left -= 1
                self.resendSeconds = left
            }
        }
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
