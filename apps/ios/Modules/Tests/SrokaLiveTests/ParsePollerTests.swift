import Foundation
import Synchronization
import Testing

@testable import SrokaLive

/// What the poller's closures read and do; a test flips it.
private final class PollFlags: Sendable {
    let pending = Mutex(true)
    let signedIn = Mutex(true)
    let pulls = Mutex(0)
    let onPull = Mutex<(@Sendable (PollFlags) -> Void)?>(nil)
    let queries = Mutex(0)
    /// The query with this number waits for `gate`.
    let blockQuery = Mutex<Int?>(nil)
    let gate = QueryGate()

    func setPending(_ value: Bool) { pending.withLock { $0 = value } }
    func setSignedIn(_ value: Bool) { signedIn.withLock { $0 = value } }
}

/// A poller over a manual clock. `pull` records itself and runs `onPull` (a test makes the parse finish there).
private final class PollHarness: Sendable {
    let clock = PollClock()
    let flags = PollFlags()
    let poller: ParsePoller

    init() {
        let flags = flags
        poller = ParsePoller(
            clock: clock,
            canPoll: { flags.signedIn.withLock { $0 } },
            hasPendingParse: {
                let query = flags.queries.withLock { count -> Int in
                    count += 1
                    return count
                }
                if flags.blockQuery.withLock({ $0 }) == query { await flags.gate.wait() }
                return flags.pending.withLock { $0 }
            },
            pull: {
                flags.pulls.withLock { $0 += 1 }
                flags.onPull.withLock { $0 }?(flags)
            })
    }

    var pullCount: Int { flags.pulls.withLock { $0 } }

    /// Waits for the round's next sleep, then lets it elapse.
    func elapseNextSleep() async {
        await clock.waitForSleepers()
        clock.advance(by: clock.pendingDelay ?? .zero)
    }
}

/// Holds one pending-row query until opened.
private final class QueryGate: Sendable {
    private let state = Mutex<(open: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    var isWaiting: Bool { state.withLock { $0.waiter != nil } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiter = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.open = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

@Suite struct ParsePollerTests {
    @Test func `A round backgrounded during its query neither pulls nor overlaps the next round`() async {
        let harness = PollHarness()
        // Query 1 starts the round; query 2 is the check after the first sleep, held while the app backgrounds.
        harness.flags.blockQuery.withLock { $0 = 2 }
        harness.poller.setActive(true)
        await harness.elapseNextSleep()
        await pollEventually { harness.flags.gate.isWaiting }
        harness.poller.setActive(false)
        harness.poller.setActive(true)
        // The old round is still unwinding: no second round starts beside it.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.clock.sleeperCount == 0)

        harness.flags.gate.open()
        // The old round exits without pulling; one new round replaces it because the app is active again.
        await harness.clock.waitForSleepers()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.pullCount == 0)
        #expect(harness.clock.sleeperCount == 1)
        #expect(harness.poller.isPolling)
        harness.poller.setActive(false)
    }

    @Test func `Polling starts when an item waits for its parse and backs off`() async {
        let harness = PollHarness()
        harness.poller.setActive(true)
        for expected in 1...3 {
            await harness.elapseNextSleep()
            await pollEventually { harness.pullCount == expected }
        }
        await harness.clock.waitForSleepers()
        #expect(harness.clock.requested == [.seconds(2), .seconds(4), .seconds(8), .seconds(16)])
        #expect(harness.poller.isPolling)
        harness.poller.setActive(false)
    }

    @Test func `Nothing pending means no polling`() async {
        let harness = PollHarness()
        harness.flags.setPending(false)
        harness.poller.setActive(true)
        await pollEventually { !harness.poller.isPolling }
        harness.clock.advance(by: .seconds(600))
        #expect(harness.pullCount == 0)
        #expect(harness.clock.requested.isEmpty)
    }

    @Test func `Polling stops once nothing is pending`() async {
        let harness = PollHarness()
        harness.flags.onPull.withLock { $0 = { $0.setPending(false) } }
        harness.poller.setActive(true)
        await harness.elapseNextSleep()
        await pollEventually { harness.pullCount == 1 && !harness.poller.isPolling }
        harness.clock.advance(by: .seconds(600))
        #expect(harness.pullCount == 1)
        #expect(harness.clock.sleeperCount == 0)
    }

    @Test func `Backgrounding stops polling at once`() async {
        let harness = PollHarness()
        harness.poller.setActive(true)
        await harness.elapseNextSleep()
        await pollEventually { harness.pullCount == 1 }
        await harness.clock.waitForSleepers()
        harness.poller.setActive(false)
        #expect(!harness.poller.isPolling)
        await pollEventually { harness.clock.sleeperCount == 0 }
        harness.clock.advance(by: .seconds(600))
        // Give a round that ignored the cancellation time to pull.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.pullCount == 1)
        // A finished sync pass in the background starts nothing.
        harness.poller.kick()
        #expect(!harness.poller.isPolling)
    }

    @Test func `Signing out stops polling`() async {
        let harness = PollHarness()
        harness.flags.onPull.withLock { $0 = { $0.setSignedIn(false) } }
        harness.poller.setActive(true)
        await harness.elapseNextSleep()
        await pollEventually { harness.pullCount == 1 && !harness.poller.isPolling }
        harness.clock.advance(by: .seconds(600))
        #expect(harness.pullCount == 1)
        // Signed out, a finished pass starts nothing either.
        harness.poller.kick()
        await pollEventually { !harness.poller.isPolling }
        #expect(harness.clock.sleeperCount == 0)
    }

    @Test func `A finished sync pass starts a new round while active`() async {
        let harness = PollHarness()
        harness.flags.setPending(false)
        harness.poller.setActive(true)
        await pollEventually { !harness.poller.isPolling }
        harness.flags.setPending(true)
        harness.poller.kick()
        await harness.elapseNextSleep()
        await pollEventually { harness.pullCount == 1 }
        harness.poller.setActive(false)
    }

    @Test func `A round gives up after five minutes`() async {
        let harness = PollHarness()
        harness.poller.setActive(true)
        // 2+4+8+16 = 30 s, then 30 s steps until 300 s have been waited: 13 pulls.
        for expected in 1...13 {
            await harness.elapseNextSleep()
            await pollEventually { harness.pullCount == expected }
        }
        await pollEventually { !harness.poller.isPolling }
        let requested = harness.clock.requested
        #expect(requested.count == 13)
        #expect(requested.allSatisfy { $0 <= ParsePoller.maxDelay })
        #expect(requested.reduce(.zero, +) == ParsePoller.giveUpAfter)
        #expect(harness.clock.sleeperCount == 0)
    }
}

/// A clock whose time moves only when a test calls `advance`; records every requested sleep.
private final class PollClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var id: Int
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextId = 0
        var sleepers: [Sleeper] = []
        var requested: [Duration] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }
    var requested: [Duration] { state.withLock { $0.requested } }
    /// Time left until the earliest sleeper's deadline.
    var pendingDelay: Duration? {
        state.withLock { state in state.sleepers.map { state.now.duration(to: $0.deadline) }.min() }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextId += 1
            return state.nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.requested.append(state.now.duration(to: deadline))
                    if deadline <= state.now { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if resumeNow {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    func waitForSleepers(_ count: Int = 1) async {
        await pollEventually { self.sleeperCount >= count }
    }
}

/// Yields until `condition` holds (bounded); records an issue when it never does.
private func pollEventually(
    _ condition: @Sendable () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<2_000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("condition not met in time", sourceLocation: sourceLocation)
}
