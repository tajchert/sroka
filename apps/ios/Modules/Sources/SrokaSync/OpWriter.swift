import GRDB
import SrokaCore
import SrokaDatabase

/// Time and ids for the ops of one local write.
public struct OpContext: Sendable {
    /// The op time (`OpClock`, strictly increasing across writes).
    public let at: Int64

    /// A fresh UUIDv7 op id (or item id) for this write.
    public func newId() -> String { UUIDv7.next(nowMilliseconds: at) }
}

/// Lets the composition root close the local write path: a sign-out wipe waits for admitted writes to finish, then
/// refuses new ones until it ends, so no old-account op lands after the tables are cleared.
public protocol OpWriteAdmission: Sendable {
    /// Runs `body`, or throws without running it while local writes are closed.
    func admit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T
}

/// Local-first write path (DECISIONS A7): in ONE transaction, applies each op's local effect (rows +
/// FTS) and queues its canonical payload in `pending_ops`, where `PendingOpDao.enqueue` coalesces
/// older unsent ops of the same item and type. Ops whose target item does not exist are dropped.
/// Android: `ops/OpWriter.kt`.
public struct OpWriter: Sendable {
    let database: AppDatabase
    let opClock: OpClock
    let now: @Sendable () -> Int64
    let admission: (any OpWriteAdmission)?

    /// - Parameters:
    ///   - opClock: source of op `at` values; give it a `FileOpClockStore` next to the shared database so the app
    ///     and the share extension share one clock.
    ///   - now: wall-clock milliseconds for `pending_ops.created_at`.
    ///   - admission: closes the write path during a wipe (app); nil writes always.
    public init(
        database: AppDatabase, opClock: OpClock, now: @escaping @Sendable () -> Int64 = systemNowMillis,
        admission: (any OpWriteAdmission)? = nil
    ) {
        self.database = database
        self.opClock = opClock
        self.now = now
        self.admission = admission
    }

    /// `build` runs inside the transaction and returns the ops plus a value for the caller.
    /// Returns whether any op was queued, and the value.
    ///
    /// The clock ticks inside the write transaction. Write transactions are `IMMEDIATE`, so SQLite serialises them
    /// across processes: with a shared `OpClockStore` (`FileOpClockStore`), the app and the share extension never
    /// issue the same `at`, and `at` grows in commit (`local_seq`) order.
    public func write<T: Sendable>(
        _ build: @escaping @Sendable (Database, OpContext) throws -> (ops: [WireOp], value: T)
    ) async throws -> (queued: Bool, value: T) {
        let database = database
        let commit: @Sendable () async throws -> (queued: Bool, value: T) = { [opClock, now] in
            let createdAt = now()
            return try await database.write { db in
                let context = OpContext(at: opClock.next())
                let (ops, value) = try build(db, context)
                var queued = false
                for op in ops where try LocalOpApplier.apply(db, op) {
                    try PendingOpDao.enqueue(db, op.pendingRecord(createdAt: createdAt))
                    queued = true
                }
                return (queued, value)
            }
        }
        guard let admission else { return try await commit() }
        return try await admission.admit(commit)
    }

    /// `write` without a value. Returns whether any op was queued.
    @discardableResult
    public func write(_ build: @escaping @Sendable (Database, OpContext) throws -> [WireOp]) async throws -> Bool {
        try await write { db, context in (ops: try build(db, context), value: ()) }.queued
    }
}

extension WireOp {
    func pendingRecord(createdAt: Int64) -> PendingOpRecord {
        PendingOpRecord(opId: opId, itemId: itemId, type: kind.rawValue, payload: payload, createdAt: createdAt)
    }
}
