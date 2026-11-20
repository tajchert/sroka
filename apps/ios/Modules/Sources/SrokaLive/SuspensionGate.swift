import Foundation
import Synchronization

/// Decides when the shared database is suspended (0xDEAD10CC: a suspended app must not hold a file lock in the
/// App Group container).
///
/// The database runs while the app is in the foreground or while background work holds it (a background task, the
/// flush on backgrounding). It is suspended once the app is in the background and the last hold is released.
public final class SuspensionGate: Sendable {
    private struct State {
        var foreground = false
        var suspended = false
        /// Outstanding holds by the epoch they were taken in.
        var holds: [Int: Int] = [:]
        var epoch = 0
        /// Holds from epochs below this no longer keep the database running (background time expired after they were
        /// taken). 0: every hold counts.
        var barrier = 0

        var liveHolds: Int { holds.reduce(0) { $0 + ($1.key >= barrier ? $1.value : 0) } }
    }

    private let state = Mutex(State())
    private let suspend: @Sendable () -> Void
    private let resume: @Sendable () -> Void

    public init(suspend: @escaping @Sendable () -> Void, resume: @escaping @Sendable () -> Void) {
        self.suspend = suspend
        self.resume = resume
    }

    public func enterForeground() {
        update {
            $0.foreground = true
            $0.barrier = 0
        }
    }

    public func enterBackground() {
        update { $0.foreground = false }
    }

    /// The system is about to suspend the app (UIKit background time expired): suspend the database now, whatever
    /// still holds it. Holds taken before this no longer count until the next foreground; a hold taken later (a new
    /// background task) resumes it.
    public func expire() {
        update {
            $0.foreground = false
            $0.epoch += 1
            $0.barrier = $0.epoch
        }
    }

    /// Keeps the database running until the returned hold is released.
    public func hold() -> Hold {
        var epoch = 0
        update {
            epoch = $0.epoch
            $0.holds[epoch, default: 0] += 1
        }
        return Hold(gate: self, epoch: epoch)
    }

    /// Runs `body` with the database held.
    public func holding<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        let hold = hold()
        defer { hold.release() }
        return await body()
    }

    fileprivate func release(epoch: Int) {
        update {
            let left = ($0.holds[epoch] ?? 0) - 1
            $0.holds[epoch] = left > 0 ? left : nil
        }
    }

    /// Applies `change`, then suspends or resumes when the wanted state differs. The callback runs under the lock so
    /// two transitions cannot post their notifications out of order.
    private func update(_ change: (inout State) -> Void) {
        state.withLock { state in
            change(&state)
            let wantSuspended = !state.foreground && state.liveHolds == 0
            guard wantSuspended != state.suspended else { return }
            state.suspended = wantSuspended
            if wantSuspended { suspend() } else { resume() }
        }
    }

    /// A claim on the running database. Release it exactly once; later calls do nothing.
    public final class Hold: Sendable {
        private let gate: SuspensionGate
        private let epoch: Int
        private let released = Mutex(false)

        fileprivate init(gate: SuspensionGate, epoch: Int) {
            self.gate = gate
            self.epoch = epoch
        }

        public func release() {
            let first = released.withLock { released in
                defer { released = true }
                return !released
            }
            if first { gate.release(epoch: epoch) }
        }
    }
}
