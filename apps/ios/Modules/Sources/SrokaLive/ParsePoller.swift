import Foundation
import Synchronization

/// Pulls while the app is active and an item waits for its parse result (api.md §5 "Waiting for parse"): 2 s, 4 s,
/// 8 s, … capped at 30 s, giving up after 5 minutes. The server parses after the push, so the pull that follows a save
/// usually still sees the item pending; without this the row stays "Preparing…" until the next activation.
///
/// `setActive(true)` (scene active) checks at once; `kick()` (a sync pass finished) starts a new round while active.
/// Each round stops when nothing is pending, the account cannot sync (signed out, expired, wiping) or the scene leaves
/// the foreground.
public final class ParsePoller: Sendable {
    public static let firstDelay: Duration = .seconds(2)
    public static let maxDelay: Duration = .seconds(30)
    public static let giveUpAfter: Duration = .seconds(300)

    private struct State {
        var active = false
        var loop: Task<Void, Never>?
        var generation = 0
    }

    private let state = Mutex(State())
    private let clock: any Clock<Duration>
    private let canPoll: @Sendable () -> Bool
    private let hasPendingParse: @Sendable () async -> Bool
    private let pull: @Sendable () async -> Void

    /// - Parameters:
    ///   - canPoll: signed in, not expired and not wiping.
    ///   - hasPendingParse: an item's `parseStatus` is `pending`.
    ///   - pull: one sync pass, holding the database.
    public init(
        clock: any Clock<Duration>,
        canPoll: @escaping @Sendable () -> Bool,
        hasPendingParse: @escaping @Sendable () async -> Bool,
        pull: @escaping @Sendable () async -> Void
    ) {
        self.clock = clock
        self.canPoll = canPoll
        self.hasPendingParse = hasPendingParse
        self.pull = pull
    }

    /// The scene became active (true) or left the foreground (false, stops a running round at once).
    public func setActive(_ active: Bool) {
        let cancelled = state.withLock { state -> Task<Void, Never>? in
            state.active = active
            guard !active else { return nil }
            state.generation += 1
            defer { state.loop = nil }
            return state.loop
        }
        cancelled?.cancel()
        if active { kick() }
    }

    /// Starts a round unless one runs or the scene is not active.
    public func kick() {
        state.withLock { state in
            guard state.active, state.loop == nil else { return }
            state.generation += 1
            let generation = state.generation
            state.loop = Task { [self] in
                await run()
                self.state.withLock { state in
                    if state.generation == generation { state.loop = nil }
                }
            }
        }
    }

    var isPolling: Bool { state.withLock { $0.loop != nil } }

    private func run() async {
        var delay = Self.firstDelay
        var waited: Duration = .zero
        while canPoll(), await hasPendingParse(), !Task.isCancelled {
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, canPoll(), await hasPendingParse() else { return }
            await pull()
            waited += delay
            guard waited < Self.giveUpAfter else { return }
            delay = min(delay * 2, Self.maxDelay)
        }
    }
}
