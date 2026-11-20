import Foundation
import SrokaCore

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
