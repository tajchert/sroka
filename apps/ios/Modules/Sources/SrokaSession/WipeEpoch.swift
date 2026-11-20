import Foundation

/// A record in a file beside the shared database that every wipe replaces before it clears anything, marked "in
/// progress" until the wipe finishes.
///
/// The share extension reads it at launch and again at each commit and request: a different value means the app
/// wiped since, and an in-progress value means a wipe is clearing data now, so the share writes and sends nothing.
/// Read from disk each time, unlike App Group `UserDefaults`, which another process may still hold cached. A wipe
/// that died leaves the in-progress mark; the app finishes it at its next launch
/// (`LocalDataWiper.finishInterruptedWipe`).
public enum WipeEpoch {
    public static let fileName = "wipe.epoch"
    static let wipingPrefix = "wiping:"

    /// The epoch file beside `databaseURL`, or nil for an in-memory database.
    public static func url(besideDatabaseAt databaseURL: URL) -> URL? {
        guard databaseURL.isFileURL, databaseURL.path.hasPrefix("/") else { return nil }
        return databaseURL.deletingLastPathComponent().appending(path: fileName)
    }

    /// The current epoch; nil before the first wipe.
    public static func read(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// A wipe started and has not finished.
    public static func isWiping(_ epoch: String?) -> Bool {
        epoch?.hasPrefix(wipingPrefix) == true
    }

    /// A wipe starts: a new epoch, marked in progress (atomically).
    public static func begin(at url: URL) throws {
        try Data((wipingPrefix + UUID().uuidString).utf8).write(to: url, options: .atomic)
    }

    /// The wipe finished: a new epoch, not in progress.
    public static func finish(at url: URL) throws {
        try Data(UUID().uuidString.utf8).write(to: url, options: .atomic)
    }
}
