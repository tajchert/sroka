import Foundation
import SrokaCore
import SrokaNetwork
import Synchronization
import Testing

@testable import SrokaSession

@Suite struct PushRegistrarTests {
    static let environment = PushEnvironment(apns: .sandbox, topic: "app.sroka.dev")
    static let day: Int64 = 24 * 60 * 60 * 1000
    static let alice = LivePushRegistrar.Session(owner: "owner-a", token: "tok-a")
    static let bob = LivePushRegistrar.Session(owner: "owner-b", token: "tok-b")

    /// A registrar over the harness stores, signed in as `session`, at the time in `now`.
    struct Setup {
        let h: Harness
        let registrar: LivePushRegistrar
        let now = Locked<Int64>(1_000 * PushRegistrarTests.day)
        let session = Locked<LivePushRegistrar.Session?>(PushRegistrarTests.alice)
        let sent = Locked<[PushTokenRequestDto]>([])

        init() throws {
            let h = try Harness()
            self.h = h
            let now = now
            let session = session
            registrar = LivePushRegistrar(
                api: h.api, preferences: h.preferences, environment: PushRegistrarTests.environment,
                session: { session.withLock { $0 } }, now: { now.withLock { $0 } })
            let sent = sent
            h.api.configure {
                $0.putPushToken = { body in sent.withLock { $0.append(body) } }
                $0.deletePushToken = {}
            }
        }

        var puts: Int { h.api.recorded.filter { $0 == "putPushToken" }.count }
        func advance(days: Int64) { now.withLock { $0 += days * PushRegistrarTests.day } }

        func received(_ token: String) async {
            registrar.deviceTokenReceived(token)
            await registrar.register()
        }
    }

    @Test func `A new token is registered with the build's environment and topic`() async throws {
        let s = try Setup()
        await s.received("ABCDEF0123")
        let body = try #require(s.sent.withLock { $0.first })
        #expect(
            body
                == PushTokenRequestDto(
                    platform: "apns", token: "abcdef0123", apnsEnvironment: "sandbox", apnsTopic: "app.sroka.dev"))
        #expect(
            s.h.preferences.pushRegistration
                == PushRegistrationRecord(token: "abcdef0123", owner: "owner-a", registeredAtMs: 1_000 * Self.day))
        #expect(s.h.preferences.apnsDeviceToken == "abcdef0123")
    }

    @Test func `The same token is not registered again within seven days`() async throws {
        let s = try Setup()
        await s.received("aa11")
        s.advance(days: 6)
        await s.received("aa11")
        await s.registrar.register()
        #expect(s.puts == 1)
        s.advance(days: 1)
        await s.registrar.register()
        #expect(s.puts == 2)
    }

    @Test func `A changed token is registered at once, and only the latest one`() async throws {
        let s = try Setup()
        await s.received("aa11")
        // Two callbacks before the registration runs: only the newer token goes out.
        s.registrar.deviceTokenReceived("bb22")
        s.registrar.deviceTokenReceived("cc33")
        await s.registrar.register()
        #expect(s.sent.withLock { $0.map(\.token) } == ["aa11", "cc33"])
    }

    @Test func `Another account registers even within seven days`() async throws {
        let s = try Setup()
        await s.received("aa11")
        s.session.withLock { $0 = Self.bob }
        await s.registrar.register()
        #expect(s.puts == 2)
        #expect(s.h.preferences.pushRegistration?.owner == "owner-b")
    }

    @Test func `A result that lands after the session changed is not recorded`() async throws {
        let s = try Setup()
        let session = s.session
        // Alice's request is answered after Bob signed in.
        s.h.api.configure { $0.putPushToken = { _ in session.withLock { $0 = PushRegistrarTests.bob } } }
        await s.received("aa11")
        #expect(s.h.preferences.pushRegistration == nil)
        s.h.api.configure { $0.putPushToken = { _ in } }
        await s.registrar.register()
        #expect(s.puts == 2)
        #expect(s.h.preferences.pushRegistration?.owner == "owner-b")
    }

    @Test func `A failed registration is retried on the next call`() async throws {
        let s = try Setup()
        s.h.api.configure { $0.putPushToken = { _ in throw ApiError.transport(.notConnectedToInternet) } }
        await s.received("aa11")
        #expect(s.h.preferences.pushRegistration == nil)
        s.h.api.configure { $0.putPushToken = { _ in } }
        await s.registrar.register()
        #expect(s.puts == 2)
        #expect(s.h.preferences.pushRegistration?.token == "aa11")
    }

    @Test func `Signed out, the token is kept and registered after sign-in`() async throws {
        let s = try Setup()
        s.session.withLock { $0 = nil }
        await s.received("aa11")
        #expect(s.puts == 0)
        #expect(s.h.preferences.apnsDeviceToken == "aa11")
        s.session.withLock { $0 = Self.alice }
        await s.registrar.register()
        #expect(s.puts == 1)
    }

    @Test func `No token yet means nothing to register or unregister`() async throws {
        let s = try Setup()
        await s.registrar.register()
        await s.registrar.unregister()
        #expect(s.h.api.recorded.isEmpty)
    }

    @Test func `Malformed tokens are ignored`() async throws {
        let s = try Setup()
        await s.received("not hex")
        await s.received("")
        #expect(s.h.preferences.apnsDeviceToken == nil)
        #expect(s.puts == 0)
    }

    @Test func `Unregister deletes the server row and forgets the registration, even when the call fails`()
        async throws
    {
        let s = try Setup()
        await s.received("aa11")
        s.h.api.configure { $0.deletePushToken = { throw ApiError.transport(.timedOut) } }
        await s.registrar.unregister()
        #expect(s.h.api.recorded.last == "deletePushToken")
        #expect(s.h.preferences.pushRegistration == nil)
        // The install keeps its token for the next account.
        #expect(s.h.preferences.apnsDeviceToken == "aa11")
    }

    @Test func `No registration for a session being signed out`() async throws {
        let s = try Setup()
        await s.received("aa11")
        s.advance(days: 8)
        // The sign-out removed the device but the session is still stored (the revoke call is under way).
        await s.registrar.unregister()
        await s.received("aa11")
        #expect(s.puts == 1)
        // A new sign-in (new session) registers again.
        s.session.withLock { $0 = LivePushRegistrar.Session(owner: "owner-a", token: "tok-a2") }
        await s.registrar.register()
        #expect(s.puts == 2)
    }

    @Test func `A registration in flight when the sign-out starts records nothing`() async throws {
        let s = try Setup()
        s.registrar.deviceTokenReceived("aa11")
        let registrar = s.registrar
        // The sign-out starts while the PUT is on the wire; its removal waits for the PUT, then runs.
        let removal = Locked<Task<Void, Never>?>(nil)
        s.h.api.configure {
            $0.putPushToken = { _ in removal.withLock { $0 = Task { await registrar.unregister() } } }
        }
        await registrar.register()
        await removal.withLock { $0 }?.value
        #expect(s.h.api.recorded == ["putPushToken", "deletePushToken"])
        #expect(s.h.preferences.pushRegistration == nil)
    }

    @Test(arguments: [
        (nil as PushRegistrationRecord?, "aa", Int64(0), true),
        (PushRegistrationRecord(token: "aa", owner: "o", registeredAtMs: 0), "aa", 6 * day, false),
        (PushRegistrationRecord(token: "aa", owner: "o", registeredAtMs: 0), "aa", 7 * day, true),
        (PushRegistrationRecord(token: "aa", owner: "o", registeredAtMs: 0), "bb", 1, true),
        (PushRegistrationRecord(token: "aa", owner: "other", registeredAtMs: 0), "aa", 1, true),
        (PushRegistrationRecord(token: "aa", owner: "o", registeredAtMs: 10 * day), "aa", 9 * day, true),
    ])
    func `Throttle rule`(record: PushRegistrationRecord?, token: String, now: Int64, expected: Bool) {
        #expect(LivePushRegistrar.needsRegistration(token: token, owner: "o", record: record, now: now) == expected)
    }

    @Test func `Device token bytes become lowercase hex`() {
        #expect(LivePushRegistrar.hex(Data([0x00, 0xAB, 0x0F, 0xFF])) == "00ab0fff")
    }

    // MARK: With the auth repository

    @Test func `Sign-in registers and sign-out unregisters before revoking the session, then wipes the record`()
        async throws
    {
        let h = try Harness()
        let sessionStore = h.sessionStore
        let registrar = LivePushRegistrar(
            api: h.api, preferences: h.preferences, environment: Self.environment,
            session: {
                sessionStore.current.flatMap { $0.expired ? nil : .init(owner: $0.ownerKey, token: $0.token) }
            })
        let auth = LiveAuthRepository(
            api: h.api, sessionStore: h.sessionStore, preferences: h.preferences, provider: h.provider,
            wiper: h.wiper, hasLocalData: { false }, requestSync: {}, clock: h.clock, pushRegistrar: registrar)
        h.preferences.apnsDeviceToken = "aa11"
        let provider = h.provider
        let (puts, put) = AsyncStream<Void>.makeStream()
        h.api.configure {
            $0.signIn = { _, _ in SignInResult(token: "tok", userEmail: "a@b.co") }
            $0.putPushToken = { _ in put.yield() }
            // Sent while the session token is still stored.
            $0.deletePushToken = { #expect(await provider.token() == "tok") }
            $0.signOut = {}
        }
        #expect(await auth.signIn(email: "a@b.co", code: "1") == .success)
        // The sign-in does not await the registration: wait for its PUT, then for it to finish (calls are serial).
        for await _ in puts { break }
        await registrar.register()
        #expect(h.preferences.pushRegistration?.token == "aa11")

        await auth.signOut()
        let calls = h.api.recorded
        let delete = try #require(calls.firstIndex(of: "deletePushToken"))
        let revoke = try #require(calls.firstIndex(of: "signOut"))
        #expect(delete < revoke)
        #expect(h.preferences.pushRegistration == nil)
        #expect(h.preferences.apnsDeviceToken == "aa11")
    }

    @Test func `The sign-out wipe clears the registration record`() async throws {
        let h = try Harness()
        h.preferences.pushRegistration = PushRegistrationRecord(token: "aa", owner: "o", registeredAtMs: 1)
        _ = await h.wiper.wipe()
        #expect(h.preferences.pushRegistration == nil)
    }
}
