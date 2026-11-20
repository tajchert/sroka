import Dependencies
import Foundation

/// Registers this device's APNs token with the server so it gets the silent "sync" push (D17, api.md "Push tokens").
/// Android: PushRegistrar.kt.
///
/// The app never asks for alert permission: a background push needs none. Every call is best effort; failures are
/// logged and the next launch (or sign-in) tries again.
public protocol PushRegistrar: Sendable {
    /// APNs handed the app a device token (hex). Stored at once, so the latest callback always wins; follow with
    /// `register()`. Kept across sign-outs for the next account.
    func deviceTokenReceived(_ token: String)

    /// Registers the last device token for the signed-in account (`PUT /v1/push-token`). Skipped when the same token
    /// was registered less than seven days ago, when no token is known yet, or when signed out.
    func register() async

    /// Removes this device's token from the server (`DELETE /v1/push-token`) and forgets that it was registered.
    /// Called before sign-out while the session token is still stored.
    func unregister() async
}

/// Where the server sends the push: APNs environment and topic (bundle identifier) of this build.
public struct PushEnvironment: Sendable, Hashable {
    public enum Apns: String, Sendable, Hashable {
        case sandbox
        case production
    }

    public var apns: Apns
    public var topic: String

    public init(apns: Apns, topic: String) {
        self.apns = apns
        self.topic = topic
    }

    /// From Info.plist `SrokaApnsEnvironment` (`$(APNS_SERVER_ENVIRONMENT)`) and the bundle identifier; nil when
    /// either is missing or unknown.
    public init?(infoValue: String?, bundleIdentifier: String?) {
        guard let infoValue, let apns = Apns(rawValue: infoValue), let topic = bundleIdentifier, !topic.isEmpty
        else { return nil }
        self.init(apns: apns, topic: topic)
    }
}

/// A registrar that does nothing (UI tests, previews, builds without APNs configuration).
public struct NoPushRegistrar: PushRegistrar {
    public init() {}
    public func deviceTokenReceived(_ token: String) {}
    public func register() async {}
    public func unregister() async {}
}

private struct UnimplementedPushRegistrar: PushRegistrar {
    private func fail(_ method: String) { reportUnimplemented("PushRegistrar.\(method)", key: "pushRegistrar") }

    func deviceTokenReceived(_ token: String) { fail("deviceTokenReceived") }
    func register() async { fail("register") }
    func unregister() async { fail("unregister") }
}

private enum PushRegistrarKey: TestDependencyKey {
    static let testValue: any PushRegistrar = UnimplementedPushRegistrar()
}

extension DependencyValues {
    public var pushRegistrar: any PushRegistrar {
        get { self[PushRegistrarKey.self] }
        set { self[PushRegistrarKey.self] = newValue }
    }
}
