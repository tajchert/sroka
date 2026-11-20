import Foundation
import Synchronization

/// Where an `OpClock` keeps its last value so ordering survives restarts. Implementations must be fast and
/// synchronous (a `UserDefaults` key, a row written in the caller's transaction).
public protocol OpClockStore: Sendable {
    /// The last persisted value, or 0 when there is none.
    func load() -> Int64
    func save(_ value: Int64)
}

/// Client-side op timestamps (port of shared `OpClock`, `hlc.ts`): wall-clock milliseconds forced to be strictly
/// increasing per device, so two local edits in the same millisecond are ordered. The server only clamps `at`;
/// ties across devices are broken by device id.
public final class OpClock: Sendable {
    private let now: @Sendable () -> Int64
    private let store: (any OpClockStore)?
    private let last: Mutex<Int64>

    /// - Parameters:
    ///   - now: current time in unix milliseconds (inject `\.date` from the caller).
    ///   - store: persists the last value; the clock resumes from it after a restart.
    public init(now: @escaping @Sendable () -> Int64, store: (any OpClockStore)? = nil) {
        self.now = now
        self.store = store
        self.last = Mutex(store?.load() ?? 0)
    }

    /// Next `at` for a new local op: `max(now, last + 1)`.
    public func next() -> Int64 {
        // Persist under the lock so concurrent callers cannot store values out of order.
        last.withLock { last -> Int64 in
            last = max(now(), last + 1)
            store?.save(last)
            return last
        }
    }

    /// Observe a remote/server time so local ops never go backwards relative to what this device has seen.
    public func observe(_ at: Int64) {
        last.withLock { last in
            guard at > last else { return }
            last = at
            store?.save(at)
        }
    }
}
