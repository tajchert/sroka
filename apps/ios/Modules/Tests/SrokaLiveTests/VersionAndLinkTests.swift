import Foundation
import SrokaCore
import Synchronization
import Testing

@testable import SrokaLive

struct VersionComparisonTests {
    @Test func `Bundle versions parse to their leading build number`() {
        #expect(buildNumber(fromBundleVersion: "42") == 42)
        #expect(buildNumber(fromBundleVersion: "42.1") == 42)
        #expect(buildNumber(fromBundleVersion: " 7 ") == 7)
        #expect(buildNumber(fromBundleVersion: "beta") == nil)
        #expect(buildNumber(fromBundleVersion: "") == nil)
        #expect(buildNumber(fromBundleVersion: nil) == nil)
        #expect(buildNumber(fromBundleVersion: "٣") == nil)
    }

    @Test func `Only a known build below a known minimum needs an update`() {
        #expect(isUpdateRequired(build: 3, minimum: 4))
        #expect(!isUpdateRequired(build: 4, minimum: 4))
        #expect(!isUpdateRequired(build: 5, minimum: 4))
        #expect(!isUpdateRequired(build: nil, minimum: 4))
        #expect(!isUpdateRequired(build: 3, minimum: nil))
    }
}

@MainActor
struct VersionGateTests {
    @Test func `A higher minimum blocks and a lower one unblocks`() async {
        let minimum = Mutex<Int??>(.some(10))
        let gate = VersionGate(build: 5, fetchMinimum: { minimum.withLock { $0 } })
        await gate.check()
        #expect(gate.updateRequired)
        #expect(gate.minimumBuild == 10)

        minimum.withLock { $0 = .some(3) }
        await gate.check()
        #expect(!gate.updateRequired)
    }

    @Test func `A failed check keeps the previous answer`() async {
        let minimum = Mutex<Int??>(.some(10))
        let gate = VersionGate(build: 5, fetchMinimum: { minimum.withLock { $0 } })
        await gate.check()
        minimum.withLock { $0 = nil }
        await gate.check()
        #expect(gate.updateRequired)
    }

    @Test func `A server switch drops the previous server's answer`() async {
        let server = Mutex("https://a.example")
        let minimum = Mutex<Int??>(.some(10))
        let gate = VersionGate(
            build: 5, server: { server.withLock { $0 } }, fetchMinimum: { minimum.withLock { $0 } })
        await gate.check()
        #expect(gate.updateRequired)
        server.withLock { $0 = "https://b.example" }
        minimum.withLock { $0 = nil }
        await gate.check()
        #expect(!gate.updateRequired)
    }

    @Test func `A reply that arrives after a server switch is ignored`() async {
        let server = Mutex("https://a.example")
        let gate = VersionGate(
            build: 5, server: { server.withLock { $0 } },
            fetchMinimum: {
                server.withLock { $0 = "https://b.example" }
                return .some(10)
            })
        await gate.check()
        #expect(!gate.updateRequired)
    }

    @Test func `A server switch while signed out triggers a check`() async throws {
        let servers = AsyncStream<String>.makeStream()
        let fetches = Mutex(0)
        let model = AppModel(
            sessionStates: { AsyncStream { $0.yield(.signedOut) } },
            serverChanges: { servers.stream },
            versionGate: VersionGate(
                build: 5,
                fetchMinimum: {
                    fetches.withLock { $0 += 1 }
                    return .some(nil)
                }),
            deepLinks: DeepLinkInbox(scheme: "sroka-dev"))
        model.start()
        servers.continuation.yield("https://a.example")
        servers.continuation.yield("https://b.example")
        try await waitUntil { fetches.withLock { $0 } == 1 }
    }

    @Test func `A server without a minimum never blocks`() async {
        let gate = VersionGate(build: 5, fetchMinimum: { .some(nil) })
        await gate.check()
        #expect(!gate.updateRequired)
    }
}

struct DeepLinkTests {
    private func link(_ string: String) -> DeepLink? {
        DeepLink(url: URL(string: string)!, scheme: "sroka-dev")
    }

    @Test func `An item link parses its id`() {
        #expect(link("sroka-dev://item/abc_DEF-123") == .item(id: "abc_DEF-123"))
        #expect(link("SROKA-DEV://item/abc") == .item(id: "abc"))
        #expect(link("sroka-dev://item/abc/") == .item(id: "abc"))
        #expect(link("sroka-dev://item/abc?from=widget#top") == .item(id: "abc"))
    }

    @Test func `Other links are rejected`() {
        #expect(link("sroka://item/abc") == nil)
        #expect(link("https://item/abc") == nil)
        #expect(link("sroka-dev://tag/abc") == nil)
        #expect(link("sroka-dev://item/") == nil)
        #expect(link("sroka-dev://item") == nil)
        #expect(link("sroka-dev://item/a/b") == nil)
        #expect(link("sroka-dev://item/..") == nil)
        #expect(link("sroka-dev://item/a%2Fb") == nil)
        #expect(link("sroka-dev://item/a%20b") == nil)
        #expect(link("sroka-dev://user@item/abc") == nil)
        #expect(link("sroka-dev://item:80/abc") == nil)
        #expect(link("sroka-dev://item/" + String(repeating: "a", count: 65)) == nil)
    }

    @Test @MainActor func `The inbox holds one pending item until it is consumed`() {
        let inbox = DeepLinkInbox(scheme: "sroka-dev")
        #expect(!inbox.handle(URL(string: "sroka-dev://item/a%2Fb")!))
        #expect(inbox.pendingItemId == nil)
        #expect(inbox.handle(URL(string: "sroka-dev://item/one")!))
        #expect(inbox.handle(URL(string: "sroka-dev://item/two")!))
        #expect(inbox.pendingItemId == "two")
        #expect(inbox.consumePendingItem() == "two")
        #expect(inbox.pendingItemId == nil)
        #expect(inbox.consumePendingItem() == nil)
    }
}

@MainActor
struct AppModelTests {
    @Test func `The root follows the session and the version gate`() async throws {
        let (stream, continuation) = AsyncStream<SessionState>.makeStream()
        let minimum = Mutex<Int??>(.some(1))
        // Session changes start version checks in the background. Holding every read until the test releases it
        // means no read can answer with the old minimum after the test changed it, whichever check started when.
        let release = OpenGate()
        let gate = VersionGate(
            build: 5,
            fetchMinimum: {
                await release.wait()
                return minimum.withLock { $0 }
            })
        let model = AppModel(
            sessionStates: { stream }, versionGate: gate, deepLinks: DeepLinkInbox(scheme: "sroka-dev"))
        #expect(model.root == .launching)
        model.start()

        continuation.yield(.signedOut)
        try await waitUntil { model.root == .signedOut }
        continuation.yield(.signedIn(email: "a@b.c"))
        try await waitUntil { model.root == .library }
        continuation.yield(.expired(email: "a@b.c"))
        try await waitUntil { model.session == .expired(email: "a@b.c") }
        #expect(model.root == .library)

        // The version gate has not answered yet, so it blocks nothing; once it answers 9 the root blocks.
        minimum.withLock { $0 = .some(9) }
        release.open()
        try await waitUntil { model.root == .updateRequired }
        continuation.finish()
    }
}

/// Suspends `wait()` until `open()`; once open, `wait()` returns at once.
final class OpenGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let all = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in all { waiter.resume() }
    }
}

/// Polls `condition` on the main actor, yielding between checks, for up to about two seconds.
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Condition not met in time")
}
