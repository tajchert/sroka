import Foundation

/// A token in a file beside the shared database that every wipe replaces before it clears anything.
///
/// The share extension reads it at launch and again at each commit: a different value means the app wiped since, so
/// the share's write is refused. Read from disk each time, unlike App Group `UserDefaults`, which another process
/// may still hold cached.
public enum WipeEpoch {
    public static let fileName = "wipe.epoch"

    /// The epoch file beside `databaseURL`, or nil for an in-memory database.
    public static func url(besideDatabaseAt databaseURL: URL) -> URL? {
        guard databaseURL.isFileURL, databaseURL.path.hasPrefix("/") else { return nil }
        return databaseURL.deletingLastPathComponent().appending(path: fileName)
    }

    /// The current epoch; nil before the first wipe.
    public static func read(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Replaces the epoch (atomically).
    public static func bump(at url: URL) throws {
        try Data(UUID().uuidString.utf8).write(to: url, options: .atomic)
    }
}
