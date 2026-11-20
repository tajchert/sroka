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
        var holds = 0
        var suspended = false
        /// Background time ran out: suspended even with holds outstanding, until the next foreground.
        var expired = false
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
            $0.expired = false
        }
    }

    public func enterBackground() {
        update { $0.foreground = false }
    }

    /// The system is about to suspend the app (UIKit background time expired): suspend the database now, whatever
    /// still holds it. It stays suspended until the next foreground or until every hold from before has been released.
    public func expire() {
        update {
            $0.foreground = false
            $0.expired = true
        }
    }

    /// Keeps the database running until the returned hold is released.
    public func hold() -> Hold {
        update { $0.holds += 1 }
        return Hold(gate: self)
    }

    /// Runs `body` with the database held.
    public func holding<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        let hold = hold()
        defer { hold.release() }
        return await body()
    }

    fileprivate func release() {
        update {
            $0.holds = max(0, $0.holds - 1)
            // The holds from before the expiry are gone: a later background task may hold and resume again.
            if $0.holds == 0 { $0.expired = false }
        }
    }

    /// Applies `change`, then suspends or resumes when the wanted state differs. The callback runs under the lock so
    /// two transitions cannot post their notifications out of order.
    private func update(_ change: (inout State) -> Void) {
        state.withLock { state in
            change(&state)
            let wantSuspended = !state.foreground && (state.holds == 0 || state.expired)
            guard wantSuspended != state.suspended else { return }
            state.suspended = wantSuspended
            if wantSuspended { suspend() } else { resume() }
        }
    }

    /// A claim on the running database. Release it exactly once; later calls do nothing.
    public final class Hold: Sendable {
        private let gate: SuspensionGate
        private let released = Mutex(false)

        fileprivate init(gate: SuspensionGate) {
            self.gate = gate
        }

        public func release() {
            let first = released.withLock { released in
                defer { released = true }
                return !released
            }
            if first { gate.release() }
        }
    }
}
