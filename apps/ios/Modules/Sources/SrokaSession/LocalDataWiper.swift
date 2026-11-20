import Foundation
import GRDB
import SrokaDatabase

/// Removes everything that belongs to the signed-in account. Android: LocalDataWiper.kt.
public protocol LocalDataWiping: Sendable {
    /// Runs every wipe step; never throws. A failed step is logged and the remaining steps still run, so the token is
    /// always cleared.
    func wipe() async
}

/// The wipe in the plan's order: cancel all work, clear every table inside the sync actor, delete files, checkpoint
/// and vacuum, clear the token. The device id and preferences stay.
///
/// The sync and content engines own the table clear and most files, so the composition root passes them in:
/// - `cancelAllWork`: background tasks, URLSession tasks, sync debounce, import polling.
/// - `clearTables`: must run inside the sync actor so a running sync cannot write rows back. The default (tests,
///   or before the sync engine exists) clears the tables directly with `MaintenanceDao.wipeAll`.
/// - `deleteFiles`: articles, thumbs, pdf-uploads, temporary downloads. Exports and imports (owned here) are deleted
///   from `transferDirectories` in any case.
/// Last, the token and the account marker are cleared.
public final class LocalDataWiper: LocalDataWiping {
    public typealias Step = @Sendable () async -> Void
    public typealias ThrowingStep = @Sendable () async throws -> Void

    private let database: AppDatabase
    private let cancelAllWork: Step
    private let clearTables: ThrowingStep
    private let deleteFiles: Step
    private let transferDirectories: [URL]
    private let sessionStore: SessionStore
    private let preferences: PreferencesStore
    private let importJobs: ImportJobStore

    public init(
        database: AppDatabase,
        cancelAllWork: @escaping Step,
        clearTables: ThrowingStep? = nil,
        deleteFiles: @escaping Step,
        transferDirectories: [URL],
        sessionStore: SessionStore,
        preferences: PreferencesStore,
        importJobs: ImportJobStore
    ) {
        self.database = database
        self.cancelAllWork = cancelAllWork
        self.clearTables = clearTables ?? { try await database.write { try MaintenanceDao.wipeAll($0) } }
        self.deleteFiles = deleteFiles
        self.transferDirectories = transferDirectories
        self.sessionStore = sessionStore
        self.preferences = preferences
        self.importJobs = importJobs
    }

    /// Database-only wiper (tests): no background work, no files besides `transferDirectories`.
    public static func databaseOnly(
        _ database: AppDatabase,
        transferDirectories: [URL] = [],
        sessionStore: SessionStore,
        preferences: PreferencesStore,
        importJobs: ImportJobStore
    ) -> LocalDataWiper {
        LocalDataWiper(
            database: database, cancelAllWork: {}, deleteFiles: {}, transferDirectories: transferDirectories,
            sessionStore: sessionStore, preferences: preferences, importJobs: importJobs)
    }

    public func wipe() async {
        // Detached from the caller: leaving a screen must never leave half a wipe behind.
        await Task { await runSteps() }.value
    }

    private func runSteps() async {
        await cancelAllWork()
        // Stops import polling too: the tracker stops once its job is no longer the stored one.
        importJobs.clear()
        do {
            try await clearTables()
        } catch {
            // The account marker is cleared below, so the next sign-in sees data with no owner and wipes again.
            sessionLog.error("Wipe: clearing tables failed: \(String(describing: error), privacy: .public)")
        }
        await deleteFiles()
        for directory in transferDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            // DELETE never shrinks the file: reclaim the article text the FTS index held.
            try await database.writer.writeWithoutTransaction { db in
                if db.configuration.readonly == false, try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal" {
                    try db.checkpoint(.truncate)
                }
                try db.execute(sql: "VACUUM")
            }
        } catch {
            sessionLog.error("Wipe: checkpoint/vacuum failed: \(String(describing: error), privacy: .public)")
        }
        sessionStore.clear()
        preferences.accountEmail = nil
        preferences.accountServer = nil
    }
}
