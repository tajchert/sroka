import Foundation
import Synchronization

/// Where an `OpClock` keeps its last value so ordering survives restarts. Implementations must be fast and
/// synchronous (a small file, a `UserDefaults` key).
///
/// A store may be shared by two processes (the app and the share extension). The clock reads it on every tick, so
/// each process sees the other's values; callers in different processes must serialise their ticks (`OpWriter`
/// ticks inside the database write transaction, which SQLite serialises across processes).
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
    ///   - store: persists the last value; the clock resumes from it after a restart and follows values another
    ///     process saved to the same store.
    public init(now: @escaping @Sendable () -> Int64, store: (any OpClockStore)? = nil) {
        self.now = now
        self.store = store
        self.last = Mutex(store?.load() ?? 0)
    }

    /// Next `at` for a new local op: `max(now, last + 1)`, where `last` also covers the stored value.
    public func next() -> Int64 {
        // Persist under the lock so concurrent callers cannot store values out of order.
        last.withLock { last -> Int64 in
            last = max(now(), max(last, store?.load() ?? 0) + 1)
            store?.save(last)
            return last
        }
    }

    /// Observe a remote/server time so local ops never go backwards relative to what this device has seen.
    public func observe(_ at: Int64) {
        last.withLock { last in
            last = max(last, store?.load() ?? 0)
            guard at > last else { return }
            last = at
            store?.save(at)
        }
    }
}
