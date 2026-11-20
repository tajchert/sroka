import Foundation
import SrokaCore
import SrokaDatabase

/// `OpClockStore` in a small file next to the shared database, used by the app and the share extension alike.
///
/// A file (rather than a `UserDefaults` key) because every read must see the other process's last write at once:
/// `OpWriter` reads and saves the clock inside the database write transaction, which SQLite serialises across
/// processes, so a plain file read and atomic replace there is enough to keep the two processes' `at` values
/// unique and ordered. `UserDefaults` caches per process and gives no such guarantee.
public struct FileOpClockStore: OpClockStore {
    /// File name inside the database directory.
    public static let fileName = "op-clock"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The store beside `databaseURL` (`AppDatabase.sharedFileURL(groupIdentifier:)`).
    public init(besideDatabaseAt databaseURL: URL) {
        url = databaseURL.deletingLastPathComponent().appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    public func load() -> Int64 {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return Int64(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    public func save(_ value: Int64) {
        do {
            try Data(String(value).utf8).write(to: url, options: [.atomic])
        } catch {
            // The in-memory clock stays monotonic; only restarts and the other process lose this value.
            syncLog.error("op clock not persisted")
        }
    }
}

/// Several stores read as one: loads the largest value, saves to all. The app and the share extension both use the
/// App Group `UserDefaults` key plus a `FileOpClockStore`, so the key stays filled (older builds read it) while the
/// file gives the immediate cross-process read the key does not.
public struct CombinedOpClockStore: OpClockStore {
    let stores: [any OpClockStore]

    public init(_ stores: [any OpClockStore]) {
        self.stores = stores
    }

    public func load() -> Int64 { stores.map { $0.load() }.max() ?? 0 }

    public func save(_ value: Int64) {
        for store in stores { store.save(value) }
    }
}

/// Persists the op clock in the App Group suite, which the share extension shares.
public struct DefaultsOpClockStore: OpClockStore {
    public static let key = "sroka.opClock.last"
    /// `UserDefaults` is thread-safe; it is not marked `Sendable` in every SDK (same as `PreferencesStore`).
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> Int64 {
        (defaults.object(forKey: Self.key) as? NSNumber)?.int64Value ?? 0
    }

    public func save(_ value: Int64) {
        defaults.set(NSNumber(value: value), forKey: Self.key)
    }

    /// The op clock store the app and the share extension share: this key in the App Group suite plus a file next to
    /// the shared database (`FileOpClockStore`), which the other process reads without a per-process cache.
    public static func appGroup(_ group: String) -> any OpClockStore {
        let defaults = DefaultsOpClockStore(defaults: UserDefaults(suiteName: group) ?? .standard)
        guard let databaseURL = AppDatabase.sharedFileURL(groupIdentifier: group) else { return defaults }
        return CombinedOpClockStore([defaults, FileOpClockStore(besideDatabaseAt: databaseURL)])
    }
}
