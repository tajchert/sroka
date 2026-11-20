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
        /// The running round was cancelled and is unwinding; it stays in `loop` until it exits, so no second round
        /// starts beside it.
        var cancelled = false
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

    /// The scene became active (true) or left the foreground (false, cancels a running round at once).
    public func setActive(_ active: Bool) {
        let cancelled = state.withLock { state -> Task<Void, Never>? in
            state.active = active
            guard !active, let loop = state.loop, !state.cancelled else { return nil }
            state.cancelled = true
            return loop
        }
        cancelled?.cancel()
        if active { kick() }
    }

    /// Starts a round unless one runs or the scene is not active. A cancelled round still unwinding is replaced when
    /// it exits, if the scene is active again by then.
    public func kick() {
        state.withLock { start(&$0) }
    }

    private func start(_ state: inout State) {
        guard state.active, state.loop == nil else { return }
        state.loop = Task { [self] in
            await run()
            self.state.withLock { state in
                let restart = state.cancelled
                state.loop = nil
                state.cancelled = false
                if restart { start(&state) }
            }
        }
    }

    /// A round runs and has not been cancelled.
    var isPolling: Bool { state.withLock { $0.loop != nil && !$0.cancelled } }

    private func run() async {
        var delay = Self.firstDelay
        var waited: Duration = .zero
        while await shouldPoll() {
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard await shouldPoll() else { return }
            await pull()
            waited += delay
            guard waited < Self.giveUpAfter else { return }
            delay = min(delay * 2, Self.maxDelay)
        }
    }

    /// Checked again after the query: the scene may have left the foreground, or the account changed, meanwhile.
    private func shouldPoll() async -> Bool {
        guard !Task.isCancelled, canPoll() else { return false }
        let pending = await hasPendingParse()
        return pending && !Task.isCancelled && canPoll()
    }
}
