import Foundation
import GRDB
import SQLite3
import SrokaCore

/// The app's database: one SQLite file in the App Group container, shared by the app and the share
/// extension (GRDB "Sharing a Database" guide). Reads and writes go through `writer`; the DAOs
/// (`ItemDao`, `SearchDao`, `TagDao`, `PendingOpDao`, `SyncStateDao`, `ContentFileDao`,
/// `MaintenanceDao`) are functions of a GRDB `Database`, so one `write { }` can combine several.
///
/// - The app opens with `openShared(at:)`, which runs migrations under `NSFileCoordinator`.
/// - The extension opens with `openForExtension(at:)`, which never migrates and throws
///   `DatabaseOpenError.needsAppUpdate` unless the file exists and is migrated to this schema.
/// - Tests and previews use `inMemory()`.
public final class AppDatabase: Sendable {
    /// File name inside the App Group container.
    public static let fileName = "sroka.sqlite"

    public let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: Opening

    /// The database file inside the App Group container `groupIdentifier`
    /// (`group.app.sroka` or `group.app.sroka.dev`); nil when the entitlement is missing.
    public static func sharedFileURL(groupIdentifier: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appending(path: "Database", directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }

    /// App side: creates the file if needed and migrates it, coordinated with the extension.
    /// Throws `DatabaseOpenError.supersededSchema` when a newer app version wrote the file.
    public static func openShared(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try coordinated(url) { url in
            let pool = try DatabasePool(path: url.path, configuration: configuration(readonly: false))
            let migrator = Schema.migrator
            if try pool.read(migrator.hasBeenSuperseded) { throw DatabaseOpenError.supersededSchema }
            try migrator.migrate(pool)
            return pool
        }
        return AppDatabase(writer: pool)
    }

    /// Extension side: opens the file only when the app already created and fully migrated it.
    /// Never migrates. Throws `DatabaseOpenError.needsAppUpdate` otherwise ("Open Sroka to finish
    /// updating").
    public static func openForExtension(at url: URL) throws -> AppDatabase {
        guard FileManager.default.fileExists(atPath: url.path) else { throw DatabaseOpenError.needsAppUpdate }
        let pool = try coordinated(url) { url in
            try DatabasePool(path: url.path, configuration: configuration(readonly: false))
        }
        let current = try pool.read { db in
            try Schema.migrator.hasCompletedMigrations(db) && !Schema.migrator.hasBeenSuperseded(db)
        }
        guard current else {
            try? pool.close()
            throw DatabaseOpenError.needsAppUpdate
        }
        return AppDatabase(writer: pool)
    }

    /// A fresh, migrated in-memory database (tests, previews).
    public static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: configuration(readonly: false, shared: false))
        try Schema.migrator.migrate(queue)
        return AppDatabase(writer: queue)
    }

    static func configuration(readonly: Bool, shared: Bool = true) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = readonly
        configuration.foreignKeysEnabled = true
        if shared {
            // Another process may hold the lock briefly.
            configuration.busyMode = .timeout(5)
            // Release locks when the app is suspended (0xDEAD10CC); see `suspend()` / `resume()`.
            configuration.observesSuspensionNotifications = true
            configuration.prepareDatabase { db in
                // Persistent WAL: the -wal and -shm files outlive connections, so a process that
                // opens later never needs write access to recreate them.
                if !db.configuration.readonly {
                    var flag: CInt = 1
                    let code = withUnsafeMutablePointer(to: &flag) { pointer in
                        sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, pointer)
                    }
                    guard code == SQLITE_OK else { throw DatabaseError(resultCode: ResultCode(rawValue: code)) }
                }
            }
        }
        return configuration
    }

    /// Runs `open` under a coordinated write of `url` (creation and migration only).
    private static func coordinated<T>(_ url: URL, _ open: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: Result<T, any Error>?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinatorError) { url in
            result = Result { try open(url) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw DatabaseOpenError.coordinationFailed }
        return try result.get()
    }

    // MARK: Suspension (0xDEAD10CC)

    /// Call when the app or extension moves to the background: open databases release their
    /// locks, and accesses fail with `SQLITE_INTERRUPT` until `resume()`.
    public static func suspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    /// Call when the app or extension becomes active again.
    public static func resume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    // MARK: Access

    public func read<T: Sendable>(_ value: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writer.read(value)
    }

    /// One write transaction.
    public func write<T: Sendable>(_ updates: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writer.write(updates)
    }

    /// Observes `value`, starting with the current value, re-fetched after every committed change
    /// (made through `writer`) to the tables it reads; equal consecutive values are dropped.
    /// Writes by the other process are not seen until `notifyExternalChanges()` runs.
    public func observe<T: Sendable & Equatable>(
        _ value: @escaping @Sendable (Database) throws -> T
    ) -> AsyncValueObservation<T> {
        ValueObservation.tracking(value).removeDuplicates().values(in: writer)
    }

    /// Makes every observation re-fetch. Call when the app becomes active, because the share
    /// extension may have written to the file meanwhile and GRDB only sees this process's writes.
    public func notifyExternalChanges() async throws {
        try await writer.write { db in
            for table in Schema.tables { try db.notifyChanges(in: Table(table)) }
        }
    }
}

/// Why a database could not be opened.
public enum DatabaseOpenError: Error, Sendable, Equatable {
    /// The extension found no database or one with pending migrations: the app must run first.
    case needsAppUpdate
    /// The file was migrated by a newer app version than this one.
    case supersededSchema
    /// `NSFileCoordinator` neither ran the accessor nor reported an error.
    case coordinationFailed
}

// MARK: - Observations

extension AppDatabase {
    public func observeItems(_ query: ItemQuery, limit: Int) -> AsyncValueObservation<ItemPage> {
        observe { db in try ItemDao.page(db, query: query, limit: limit) }
    }

    public func observeSearch(_ query: String, scope: SearchScope, limit: Int) -> AsyncValueObservation<SearchPage> {
        observe { db in try SearchDao.page(db, query: query, scope: scope, limit: limit) }
    }

    public func observeSearchCount(_ query: String, scope: SearchScope) -> AsyncValueObservation<Int> {
        observe { db in try SearchDao.count(db, query: query, scope: scope) }
    }

    public func observeContinueReading(limit: Int) -> AsyncValueObservation<[ItemSummary]> {
        observe { db in try ItemDao.continueReading(db, limit: limit).map { $0.toSummary() } }
    }

    public func observeItem(id: String) -> AsyncValueObservation<Item?> {
        observe { db in try ItemDao.detail(db, id: id)?.toItem() }
    }

    public func observeNextUnread(excludeId: String?) -> AsyncValueObservation<ItemSummary?> {
        observe { db in try ItemDao.nextUnread(db, excludeId: excludeId)?.toSummary() }
    }

    public func observeNextReadable(excludeId: String?) -> AsyncValueObservation<ItemSummary?> {
        observe { db in try ItemDao.nextReadable(db, excludeId: excludeId)?.toSummary() }
    }

    public func observeCounts() -> AsyncValueObservation<LibraryCounts> {
        observe { db in try ItemDao.counts(db) }
    }

    public func observeTagCounts() -> AsyncValueObservation<[TagCount]> {
        observe { db in try TagDao.counts(db) }
    }

    public func observeRecentTags(limit: Int) -> AsyncValueObservation<[String]> {
        observe { db in try TagDao.recent(db, limit: limit) }
    }

    public func observePendingOpCount() -> AsyncValueObservation<Int> {
        observe { db in try PendingOpDao.count(db) }
    }

    public func observeSyncState() -> AsyncValueObservation<SyncStateRecord> {
        observe { db in try SyncStateDao.get(db) }
    }

    public func observeContentFile(itemId: String) -> AsyncValueObservation<ContentFileRecord?> {
        observe { db in try ContentFileDao.get(db, itemId: itemId) }
    }

    /// Offline state of one item (item `content_id` against its content file row).
    public func observeOffline(itemId: String) -> AsyncValueObservation<OfflineState> {
        observe { db in
            let contentId = try String.fetchOne(
                db, sql: "SELECT content_id FROM items WHERE id = ?", arguments: [itemId])
            let file = try ContentFileDao.get(db, itemId: itemId)
            return deriveOffline(contentId: contentId, fileContentId: file?.contentId, fileState: file?.state)
        }
    }

    public func observeEligibleDownloadCount() -> AsyncValueObservation<Int> {
        observe { db in try ContentFileDao.eligibleCount(db) }
    }

    public func observeDownloadedCount() -> AsyncValueObservation<Int> {
        observe { db in try ContentFileDao.downloadedCount(db) }
    }

    public func observeDownloadedBytes() -> AsyncValueObservation<Int64> {
        observe { db in try ContentFileDao.totalBytes(db) }
    }
}
