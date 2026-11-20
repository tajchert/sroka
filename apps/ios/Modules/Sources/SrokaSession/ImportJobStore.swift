import Foundation
import SrokaCore

/// The last started import job, persisted in the App Group defaults (`active_import`) so polling resumes on the next
/// launch. Android: ImportJobStore.kt.
public final class ImportJobStore: Sendable {
    private struct Stored: Codable {
        var id: String
        var status: String
        var format: String
        var total: Int?
        var done: Int
        var skipped: Int
        var error: String?
        var createdAt: Double
        var updatedAt: Double

        init(_ job: ImportJob) {
            id = job.id
            status = job.status.rawValue
            format = job.format.rawValue
            total = job.total
            done = job.done
            skipped = job.skipped
            error = job.error
            createdAt = job.createdAt.timeIntervalSince1970
            updatedAt = job.updatedAt.timeIntervalSince1970
        }

        var job: ImportJob? {
            guard let format = ImportFormat(rawValue: format) else { return nil }
            return ImportJob(
                id: id, status: JobStatus(wire: status), format: format, total: total, done: done, skipped: skipped,
                error: error, createdAt: Date(timeIntervalSince1970: createdAt),
                updatedAt: Date(timeIntervalSince1970: updatedAt))
        }
    }

    private let preferences: PreferencesStore
    private let value: CurrentValue<ImportJob?>
    private let lock = NSLock()
    /// Number of `clear()` calls (wipes); guarded by `lock`.
    private nonisolated(unsafe) var clears = 0

    public init(preferences: PreferencesStore) {
        self.preferences = preferences
        value = CurrentValue(Self.decode(preferences.activeImportData))
    }

    public var current: ImportJob? { value.value }

    public func stream() -> AsyncStream<ImportJob?> { value.stream() }

    public func set(_ job: ImportJob) {
        lock.withLock { persist(job) }
    }

    /// Token for `set(_:ifNotClearedSince:)`; read it before starting an upload.
    public var generation: Int { lock.withLock { clears } }

    /// Writes `job` unless a wipe cleared the store after `generation` was read. Returns false when it was not written.
    public func set(_ job: ImportJob, ifNotClearedSince generation: Int) -> Bool {
        lock.withLock {
            guard clears == generation else { return false }
            persist(job)
            return true
        }
    }

    /// Writes `job` only while it is still the active one (a newer import may have replaced it).
    /// Returns false when it was not written.
    @discardableResult
    public func update(_ job: ImportJob) -> Bool {
        lock.withLock {
            guard value.value?.id == job.id else { return false }
            persist(job)
            return true
        }
    }

    public func clear() {
        lock.withLock {
            clears += 1
            preferences.activeImportData = nil
            value.send(nil)
        }
    }

    private func persist(_ job: ImportJob) {
        preferences.activeImportData = try? JSONEncoder().encode(Stored(job))
        value.send(job)
    }

    private static func decode(_ data: Data?) -> ImportJob? {
        data.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }?.job
    }
}
