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

/// Local-first write path (DECISIONS A7): in ONE transaction, applies each op's local effect (rows +
/// FTS) and queues its canonical payload in `pending_ops`, where `PendingOpDao.enqueue` coalesces
/// older unsent ops of the same item and type. Ops whose target item does not exist are dropped.
/// Android: `ops/OpWriter.kt`.
public struct OpWriter: Sendable {
    let database: AppDatabase
    let opClock: OpClock
    let now: @Sendable () -> Int64

    /// - Parameters:
    ///   - opClock: source of op `at` values (shared with the share extension through its store).
    ///   - now: wall-clock milliseconds for `pending_ops.created_at`.
    public init(database: AppDatabase, opClock: OpClock, now: @escaping @Sendable () -> Int64 = systemNowMillis) {
        self.database = database
        self.opClock = opClock
        self.now = now
    }

    /// `build` runs inside the transaction and returns the ops plus a value for the caller.
    /// Returns whether any op was queued, and the value.
    public func write<T: Sendable>(
        _ build: @escaping @Sendable (Database, OpContext) throws -> (ops: [WireOp], value: T)
    ) async throws -> (queued: Bool, value: T) {
        let context = OpContext(at: opClock.next())
        let createdAt = now()
        return try await database.write { db in
            let (ops, value) = try build(db, context)
            var queued = false
            for op in ops where try LocalOpApplier.apply(db, op) {
                try PendingOpDao.enqueue(db, op.pendingRecord(createdAt: createdAt))
                queued = true
            }
            return (queued, value)
        }
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
