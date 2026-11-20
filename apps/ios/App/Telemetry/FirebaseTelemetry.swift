import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
import Foundation
import SrokaCore
import Synchronization

/// Firebase Analytics (without the advertising-identifier module) and Crashlytics, behind the `Telemetry` protocol
/// (repo-root D15). Android: FirebaseTelemetry.kt.
///
/// Created only by `makeTelemetry()`, which has already checked that this is a release build with a real config file.
/// Collection is off in Info.plist, so nothing is sent until `ConsentApplier` calls `setAnalyticsEnabled` /
/// `setCrashReportingEnabled` with the stored consent. No user id is ever set, and events carry the enum-only
/// parameters of `TelemetryEvent`.
final class FirebaseTelemetry: Telemetry {
    private let analyticsEnabled = Mutex(false)

    /// Configures the default `FirebaseApp` from the bundled plist. Call once, from `makeTelemetry()`.
    init?(options: FirebaseOptions) {
        guard FirebaseApp.app() == nil else { return nil }
        FirebaseApp.configure(options: options)
        // Redundant with Info.plist, but keeps the default safe if a key is ever dropped from it.
        Analytics.setAnalyticsCollectionEnabled(false)
        Analytics.setConsent(Self.consentSettings(analyticsStorage: false))
    }

    var isAvailable: Bool { true }

    func logEvent(_ event: TelemetryEvent) {
        guard analyticsEnabled.withLock({ $0 }) else { return }
        Analytics.logEvent(event.name, parameters: event.parameters)
    }

    func setAnalyticsEnabled(_ enabled: Bool) {
        analyticsEnabled.withLock { $0 = enabled }
        Analytics.setAnalyticsCollectionEnabled(enabled)
        Analytics.setConsent(Self.consentSettings(analyticsStorage: enabled))
    }

    func setCrashReportingEnabled(_ enabled: Bool) {
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(enabled)
    }

    func recordNonFatal(_ error: any Error) {
        // Only domain and code leave the device: an error's `userInfo` and message can carry URLs or file names
        // (for example `NSURLErrorFailingURLStringErrorKey`), which D15 forbids.
        let bridged = error as NSError
        Crashlytics.crashlytics().record(error: NSError(domain: bridged.domain, code: bridged.code))
    }

    /// Consent Mode v2: only `analytics_storage` can be granted; ad signals stay denied.
    private static func consentSettings(analyticsStorage: Bool) -> [ConsentType: ConsentStatus] {
        [
            .analyticsStorage: analyticsStorage ? .granted : .denied,
            .adStorage: .denied,
            .adUserData: .denied,
            .adPersonalization: .denied,
        ]
    }
}
