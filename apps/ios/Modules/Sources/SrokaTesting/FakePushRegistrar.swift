import Foundation
import SrokaCore

/// Records `PushRegistrar` calls; tokens are kept so tests can check what would have been registered.
public final class FakePushRegistrar: PushRegistrar {
    public let calls = CallRecorder<String>()
    public let deviceToken = FakeSubject<String?>(nil)

    public init() {}

    public func deviceTokenReceived(_ token: String) {
        calls.record("deviceTokenReceived")
        deviceToken.send(token)
    }

    public func register() async { calls.record("register") }
    public func unregister() async { calls.record("unregister") }
}
