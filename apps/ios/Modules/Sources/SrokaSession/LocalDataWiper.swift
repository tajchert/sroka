import Foundation
import GRDB
import SrokaDatabase

/// Removes everything that belongs to the signed-in account. Android: LocalDataWiper.kt.
public protocol LocalDataWiping: Sendable {
    /// Runs every wipe step; never throws. A failed step is logged and the remaining steps still run, so the token is
    /// always cleared. Returns false when the account's rows could not be removed.
    @discardableResult func wipe() async -> Bool
}

/// The wipe in the plan's order: cancel all work, clear every table inside the sync actor, delete files, clear the
/// token, clear tables and files again, checkpoint and vacuum. The device id and preferences stay.
///
/// The sync and content engines own the table clear and most files, so the composition root passes them in:
/// - `cancelAllWork`: background tasks, URLSession tasks, sync debounce, import polling.
/// - `clearTables`: must run inside the sync actor so a running sync cannot write rows back. The default (tests,
///   or before the sync engine exists) clears the tables directly with `MaintenanceDao.wipeAll`.
/// - `deleteFiles`: articles, thumbs, pdf-uploads, temporary downloads. Exports and imports (owned here) are deleted
///   from `transferDirectories` in any case.
/// Then the token and the account marker are cleared, and last the tables and files once more (share extension).
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

    @discardableResult public func wipe() async -> Bool {
        // Detached from the caller: leaving a screen must never leave half a wipe behind.
        await Task { await runSteps() }.value
    }

    private func runSteps() async -> Bool {
        var tablesCleared = true
        // First: a share extension commit from here on sees a new epoch and is refused (see `WipeEpoch`).
        if let epochURL = WipeEpoch.url(besideDatabaseAt: URL(filePath: database.writer.path)) {
            do {
                try WipeEpoch.bump(at: epochURL)
            } catch {
                sessionLog.error("Wipe: epoch bump failed: \(String(describing: error), privacy: .public)")
            }
        }
        await cancelAllWork()
        // Stops import polling too: the tracker stops once its job is no longer the stored one.
        importJobs.clear()
        do {
            try await clearTables()
        } catch {
            // The account marker is cleared below, so the next sign-in sees data with no owner and wipes again.
            sessionLog.error("Wipe: clearing tables failed: \(String(describing: error), privacy: .public)")
            tablesCleared = false
        }
        await deleteFiles()
        removeTransferDirectories()
        sessionStore.clear()
        preferences.accountEmail = nil
        preferences.accountServer = nil
        // An import or export that started while the token was still stored may have written since: clear again.
        importJobs.clear()
        removeTransferDirectories()
        // The share extension writes from its own process and checks, at each commit, that the Keychain still holds
        // its launch token and the account marker. A share that committed after the first clear but before they went
        // is removed here; one after this point is refused there. Same for a PDF it queued into the upload directory.
        do {
            try await clearTables()
        } catch {
            sessionLog.error("Wipe: second table clear failed: \(String(describing: error), privacy: .public)")
            tablesCleared = false
        }
        await deleteFiles()
        do {
            // After the last clear, so no deleted row (a late share included) stays in the WAL or in free pages.
            // DELETE never shrinks the file: VACUUM reclaims the article text the FTS index held, and the
            // truncating checkpoint after it empties the WAL that VACUUM wrote through.
            try await database.writer.writeWithoutTransaction { db in
                let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode")
                let wal = db.configuration.readonly == false && mode == "wal"
                if wal { try db.checkpoint(.truncate) }
                try db.execute(sql: "VACUUM")
                if wal { try db.checkpoint(.truncate) }
            }
        } catch {
            sessionLog.error("Wipe: checkpoint/vacuum failed: \(String(describing: error), privacy: .public)")
        }
        return tablesCleared
    }

    private func removeTransferDirectories() {
        for directory in transferDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
