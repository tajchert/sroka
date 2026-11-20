import Foundation
import GRDB
import SrokaCore
import SrokaDatabase
import SrokaNetwork

/// Result of one sync pass.
public enum SyncOutcome: Sendable, Hashable {
    case success(pulledItems: Int)
    case failure(SyncErrorKind)
    /// Not signed in, or the session expired: nothing ran.
    case skipped
    /// Cancelled (sign-out wipe, expired background time); `sync_state` was not updated.
    case cancelled

    /// Whether a background trigger should try again later (network or server failure).
    var isRetryable: Bool {
        if case .failure(let kind) = self { return kind != .auth }
        return false
    }
}

/// Push + pull (DECISIONS A8, api.md §7). Android: `sync/SyncEngine.kt`.
///
/// Single-flight: passes, single pushes and `wipe` run one at a time in call order behind a FIFO
/// lock (an actor alone is not enough because it is reentrant across `await`). Each pass runs in
/// its own task, so cancelling the caller (or a `wipe`) cancels the pass between transactions.
/// The engine never retries by itself; `SyncScheduler` drives retries.
public actor SyncEngine {
    private let database: AppDatabase
    private let api: any SrokaAPI
    private let session: any SyncSession
    private let hooks: any SyncContentHooks
    private let now: @Sendable () -> Int64

    private var locked = false
    private var waiters: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextWaiterId = 0
    private var inFlight: [Int: Task<SyncOutcome, Never>] = [:]
    private var nextTaskId = 0
    private let running = ValueSubject(false)

    /// - Parameter now: wall-clock milliseconds (`lastSuccessAt`, ids of re-keyed items).
    public init(
        database: AppDatabase,
        api: any SrokaAPI,
        session: any SyncSession,
        hooks: any SyncContentHooks = NoContentHooks(),
        now: @escaping @Sendable () -> Int64 = systemNowMillis
    ) {
        self.database = database
        self.api = api
        self.session = session
        self.hooks = hooks
        self.now = now
    }

    // MARK: Entry points

    /// One full pass: push every queued op, then pull until `hasMore` is false. Records the outcome
    /// in `sync_state` (`lastSuccessAt` / `lastError`). Skipped unless the session is signed in.
    public func sync() async -> SyncOutcome {
        await tracked(.full)
    }

    /// At most one push batch, no pull (share extension: bounded work after a save). Does not touch
    /// `lastSuccessAt` / `lastError`. A 401 still marks the session expired.
    public func pushOnce() async -> SyncOutcome {
        await tracked(.pushOnce)
    }

    /// Runs `body` while no pass runs (sign-out wipe). Cancels the running pass and every pass
    /// already waiting, then waits for the lock, so sync and wipe never interleave. Passes requested
    /// later run after `body` and find the session signed out.
    public func wipe(_ body: @Sendable () async throws -> Void) async rethrows {
        for task in inFlight.values { task.cancel() }
        _ = await acquire()
        defer { release() }
        try await body()
    }

    /// True while a pass (or single push) runs, current value first.
    public nonisolated func observeRunning() -> AsyncStream<Bool> { running.stream() }

    // MARK: Single flight

    private enum PassKind { case full, pushOnce }

    private func tracked(_ kind: PassKind) async -> SyncOutcome {
        let id = nextTaskId
        nextTaskId += 1
        let task = Task { await self.lockedPass(kind) }
        inFlight[id] = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inFlight[id] = nil
        return outcome
    }

    /// Waits for the lock; true once held. A `cancellable` wait leaves the queue when its task is cancelled and
    /// returns false without the lock, so a pass that ran out of time (silent push) does not linger behind another one.
    private func acquire(cancellable: Bool = false) async -> Bool {
        guard locked else {
            locked = true
            return true
        }
        if cancellable, Task.isCancelled { return false }
        nextWaiterId += 1
        let id = nextWaiterId
        guard cancellable else { return await withCheckedContinuation { waiters.append((id, $0)) } }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append((id, $0)) }
        } onCancel: {
            // Runs after the append: the hop waits for this actor, which the append holds until it suspends.
            Task { await self.leaveQueue(id) }
        }
    }

    private func leaveQueue(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func lockedPass(_ kind: PassKind) async -> SyncOutcome {
        guard await acquire(cancellable: true) else { return .cancelled }
        defer { release() }
        if Task.isCancelled { return .cancelled }
        guard case .signedIn = await session.currentState() else { return .skipped }
        if Task.isCancelled { return .cancelled }
        running.send(true)
        defer { running.send(false) }

        let outcome: SyncOutcome
        do {
            switch kind {
            case .full: outcome = .success(pulledItems: try await runSync())
            case .pushOnce:
                try await push(maxBatches: 1)
                return .success(pulledItems: 0)
            }
        } catch is CancellationError {
            return .cancelled
        } catch let failure as PassFailure {
            if kind == .pushOnce { return .failure(failure.kind) }
            outcome = .failure(failure.kind)
        } catch {
            syncLog.error("sync failed: \(String(describing: type(of: error)), privacy: .public)")
            if kind == .pushOnce { return .failure(.server) }
            outcome = .failure(.server)
        }
        await record(outcome)
        return outcome
    }

    private func record(_ outcome: SyncOutcome) async {
        let now = now()
        do {
            try await database.write { db in
                try SyncStateDao.update(db) { state in
                    switch outcome {
                    case .success:
                        state.lastSuccessAt = now
                        state.lastError = nil
                    case .failure(let kind):
                        state.lastError = kind.rawValue
                    case .skipped, .cancelled:
                        break
                    }
                }
            }
        } catch {
            syncLog.error("recording sync outcome failed")
        }
    }

    // MARK: Pass

    private struct PassFailure: Error {
        var kind: SyncErrorKind
    }

    private func runSync() async throws -> Int {
        try await push()

        // A pass that starts at cursor 0 is a "full" pass: the server never answers 410 for its later
        // pages (api.md §7.2), and rows not seen by the end of it are dropped (finishFullResync).
        try await database.write { db in
            let state = try SyncStateDao.get(db)
            if state.cursor == 0, !state.fullResync { try SyncStateDao.update(db) { $0.fullResync = true } }
        }
        var pulled = 0
        var restarted = false
        while true {
            let state = try await database.read { db in try SyncStateDao.get(db) }
            let page: PullResponseDto
            do {
                page = try await api.pull(cursor: state.cursor, limit: Limits.defaultPullLimit, full: state.fullResync)
            } catch let error as ApiError {
                if error.status == 410, !restarted {
                    // A8.3: everything local is suspect; re-pull from 0 and drop what does not come back.
                    restarted = true
                    try await startFullResync()
                    try await push()
                    continue
                }
                throw await failure(error, attempted: [])
            }
            pulled += page.items.count
            try await applyPage(page)
            if !page.hasMore { break }
        }
        if try await database.read({ db in try SyncStateDao.get(db).fullResync }) { try await finishFullResync() }
        return pulled
    }

    // MARK: Push

    /// Pushes queued ops oldest first in batches of at most `Limits.maxOpsPerPush`; never sends an
    /// empty batch. Throws `PassFailure` on the first failed batch.
    private func push(maxBatches: Int = .max) async throws {
        var sent = 0
        while sent < maxBatches {
            let batch = try await database.read { db in try PendingOpDao.batch(db, limit: Limits.maxOpsPerPush) }
            if batch.isEmpty { return }
            // As Android: only payloads that are not a JSON object are dropped; the server validates the rest.
            let corrupt = batch.filter { !isJSONObject($0.payload) }.map(\.opId)
            if !corrupt.isEmpty {
                syncLog.error("dropping \(corrupt.count, privacy: .public) corrupt queued ops")
                try await database.write { db in try PendingOpDao.delete(db, opIds: corrupt) }
                continue
            }
            sent += 1
            let opIds = batch.map(\.opId)
            let response: PushResponseDto
            do {
                response = try await api.push(payloads: batch.map(\.payload))
            } catch let error as ApiError {
                throw await failure(error, attempted: opIds)
            }
            let now = now()
            let result = try await database.write { db in
                try SyncTransactions.applyPushResponse(db, batch: batch, response: response, now: now)
            }
            await deleteFiles(result.removed)
            if !result.acknowledged {
                try await database.write { db in
                    try PendingOpDao.markAttempted(db, opIds: opIds, error: "not_acknowledged")
                }
                throw PassFailure(kind: .server)
            }
        }
    }

    /// Maps an API error to the pass failure; records the attempt on `attempted` ops for HTTP errors.
    private func failure(_ error: ApiError, attempted: [String]) async -> PassFailure {
        let kind: SyncErrorKind
        let code: String?
        switch error {
        case .transport:
            return PassFailure(kind: .network)
        case .http(let status, _, _, _):
            code = "http_\(status)"
            if status == 401 {
                await session.markExpired()
                kind = .auth
            } else {
                kind = .server
            }
        case .malformedResponse:
            code = "malformed_response"
            kind = .server
        case .invalidRequest:
            code = "invalid_request"
            kind = .server
        }
        if !attempted.isEmpty, let code {
            do {
                try await database.write { db in try PendingOpDao.markAttempted(db, opIds: attempted, error: code) }
            } catch {
                syncLog.error("marking ops attempted failed")
            }
        }
        return PassFailure(kind: kind)
    }

    // MARK: Pull

    /// One page = one transaction together with its cursor (A8.2), then queued ops are rebased.
    private func applyPage(_ page: PullResponseDto) async throws {
        let now = now()
        let removed = try await database.write { db in try SyncTransactions.applyPage(db, page: page, now: now) }
        await deleteFiles(removed)
    }

    private func startFullResync() async throws {
        try await database.write { db in
            try ItemDao.markAllForResync(db)
            try SyncStateDao.update(db) { state in
                state.cursor = 0
                state.fullResync = true
            }
        }
    }

    private func finishFullResync() async throws {
        let removed = try await database.write { db in
            let ids = try ItemDao.deleteStaleMarked(db)
            try ItemDao.clearResyncMarks(db)
            try SyncStateDao.update(db) { $0.fullResync = false }
            return ids
        }
        await deleteFiles(removed)
    }

    private func isJSONObject(_ payload: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) else { return false }
        return object is [String: Any]
    }

    private func deleteFiles(_ itemIds: [String]) async {
        let safe = itemIds.filter(isValidItemId)
        if !safe.isEmpty { await hooks.deleteItemFiles(itemIds: safe) }
    }
}

/// The transactional halves of the engine: plain functions of a GRDB `Database`, run inside one
/// `AppDatabase.write`.
enum SyncTransactions {
    static let rejectItemDeleted = "item_deleted"
    static let sqlChunk = 500

    /// Applies `applied` / `rejected` / `aliases` of one push response. Returns whether any op of
    /// `batch` was acknowledged and the items whose files must go once the transaction commits.
    static func applyPushResponse(
        _ db: Database,
        batch: [PendingOpRecord],
        response: PushResponseDto,
        now: Int64
    ) throws -> (acknowledged: Bool, removed: [String]) {
        // Only ops still queued exactly as sent. The app and the share extension may push the same batch at once;
        // by the time the later response lands, the earlier one may have deleted, coalesced or re-keyed (rewritten)
        // an op, and acting on the stale copy would delete the rewritten op from the queue.
        let live = try queuedPayloads(db, opIds: batch.map(\.opId))
        let byOpId = Dictionary(
            batch.filter { live[$0.opId] == $0.payload }.map { ($0.opId, $0) }, uniquingKeysWith: { first, _ in first })
        let acknowledged = (response.applied + response.rejected.map(\.opId)).filter { byOpId[$0] != nil }
        var removed: [String] = []

        // A re-save of a URL whose item was deleted elsewhere: keep its queued ops and re-key them to
        // a new item instead of dropping the user's save (api.md §8.2.6).
        var rekeyIds: [String] = []
        var keepQueued = Set<String>()
        for rejected in response.rejected {
            guard let op = byOpId[rejected.opId], let id = op.itemId else { continue }
            guard rejected.reason == rejectItemDeleted, isValidItemId(id) else { continue }
            if rekeyIds.contains(id) {
                keepQueued.insert(rejected.opId)
            } else if try hasQueuedAdd(db, itemId: id) {
                rekeyIds.append(id)
                keepQueued.insert(rejected.opId)
            }
        }
        try PendingOpDao.delete(db, opIds: acknowledged.filter { !keepQueued.contains($0) })
        for id in rekeyIds {
            try rekeyReAdd(db, oldId: id, now: now)
            removed.append(id)
        }

        for rejected in response.rejected {
            guard let op = byOpId[rejected.opId] else { continue }
            syncLog.notice("op \(op.type, privacy: .public) rejected: \(rejected.reason, privacy: .public)")
            guard let id = op.itemId, isValidItemId(id), !rekeyIds.contains(id) else { continue }
            if rejected.reason == rejectItemDeleted {
                try PendingOpDao.deleteForItem(db, id)
                try ItemDao.delete(db, id: id)
                removed.append(id)
            } else if op.type == WireOp.Kind.add.rawValue, try ItemDao.item(db, id: id)?.serverSeq == nil {
                // The server will never accept this add: do not keep a local-only orphan.
                try PendingOpDao.deleteForItem(db, id)
                try ItemDao.delete(db, id: id)
                removed.append(id)
            }
        }

        for (clientId, existingId) in response.aliases.sorted(by: { $0.key < $1.key }) {
            guard clientId != existingId, isValidItemId(clientId), isValidItemId(existingId) else { continue }
            // The server merged our add into an existing item: re-target queued ops. If the canonical
            // row is not local yet, re-key ours so the item survives a failed pull (the pull
            // overwrites it); otherwise drop the duplicate.
            try PendingOpDao.retargetItem(db, from: clientId, to: existingId) { op in
                WireOp.rewrite(payload: op.payload, itemId: existingId) ?? op.payload
            }
            if try ItemDao.item(db, id: existingId) != nil {
                try ItemDao.delete(db, id: clientId)
            } else {
                try ItemDao.rekey(db, from: clientId, to: existingId)
            }
            removed.append(clientId)
        }
        // Whether the server answered for this batch at all, including ops another writer has since replaced.
        let sent = Set(batch.map(\.opId))
        let answered = (response.applied + response.rejected.map(\.opId)).contains { sent.contains($0) }
        return (answered, removed)
    }

    /// Applies one pull page and its cursor; returns the deleted item ids whose files must go.
    static func applyPage(_ db: Database, page: PullResponseDto, now: Int64) throws -> [String] {
        // Ids from the server become file names and URLs: drop anything unexpected.
        let items = page.items.filter { isValidItemId($0.id) }
        if items.count != page.items.count {
            syncLog.error("ignoring \(page.items.count - items.count, privacy: .public) items with unsafe ids")
        }
        let deletedItems = page.deleted.items.filter(isValidItemId)
        for dto in items {
            try ItemDao.upsert(db, dto.toRecord(), tags: dto.tags)
        }
        if !page.deleted.tags.isEmpty { try TagDao.deleteRows(db, ids: page.deleted.tags) }
        for tag in page.tags {
            try TagDao.upsertRows(db, [TagRecord(id: tag.id, name: tag.name, nameKey: tagKey(tag.name))])
        }
        for id in deletedItems where try !rekeyReAdd(db, oldId: id, now: now) {
            try PendingOpDao.deleteForItem(db, id)
            try ItemDao.delete(db, id: id)
        }
        try rebase(db, itemIds: items.map(\.id))
        try SyncStateDao.update(db) { $0.cursor = page.cursor }
        return deletedItems
    }

    /// An item tombstoned on the server still has a queued `item.add` (the user re-saved the URL):
    /// move its queued ops to a fresh item id with fresh op ids (the server already acknowledged the
    /// old ones), drop the old row and rebuild the new one from the ops. Returns false (nothing
    /// changed) when no add is queued.
    @discardableResult
    /// `op_id` → `payload` of the queued ops among `opIds`.
    static func queuedPayloads(_ db: Database, opIds: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for start in stride(from: 0, to: opIds.count, by: sqlChunk) {
            let chunk = Array(opIds[start..<min(start + sqlChunk, opIds.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db, sql: "SELECT op_id, payload FROM pending_ops WHERE op_id IN (\(marks))",
                arguments: StatementArguments(chunk))
            for row in rows { result[row["op_id"]] = row["payload"] }
        }
        return result
    }

    static func rekeyReAdd(_ db: Database, oldId: String, now: Int64) throws -> Bool {
        let adds = try PendingOpDao.forItem(db, oldId).filter { isAdd($0) }
        if adds.isEmpty { return false }
        let newId = UUIDv7.next(nowMilliseconds: now)
        try PendingOpDao.retargetItem(db, from: oldId, to: newId) { op in
            WireOp.rewrite(payload: op.payload, itemId: newId) ?? op.payload
        }
        for add in adds {
            let newOpId = UUIDv7.next(nowMilliseconds: now)
            let payload = WireOp.rewrite(payload: add.payload, itemId: newId, opId: newOpId) ?? add.payload
            try PendingOpDao.replaceOpId(db, from: add.opId, to: newOpId, payload: payload)
        }
        try ItemDao.delete(db, id: oldId)
        try reapply(db, PendingOpDao.forItem(db, newId))
        return true
    }

    /// Re-applies queued (un-pushed) ops of `itemIds` and every queued tag-level op, so older server
    /// state does not hide local edits. A page may carry only tags, hence no early return.
    static func rebase(_ db: Database, itemIds: [String]) throws {
        if itemIds.isEmpty {
            try reapply(db, PendingOpDao.globalOps(db))
            return
        }
        for (index, start) in stride(from: 0, to: itemIds.count, by: sqlChunk).enumerated() {
            let chunk = Array(itemIds[start..<min(start + sqlChunk, itemIds.count)])
            // Tag-level ops (item_id NULL) are applied once, with the first chunk.
            try reapply(db, index == 0 ? PendingOpDao.forItemsOrGlobal(db, chunk) : PendingOpDao.forItems(db, chunk))
        }
    }

    static func reapply(_ db: Database, _ ops: [PendingOpRecord]) throws {
        for op in ops {
            if let wire = WireOp.parse(payload: op.payload) { try LocalOpApplier.apply(db, wire) }
        }
    }

    static func hasQueuedAdd(_ db: Database, itemId: String) throws -> Bool {
        try PendingOpDao.forItem(db, itemId).contains { isAdd($0) }
    }

    private static func isAdd(_ op: PendingOpRecord) -> Bool {
        if case .add = WireOp.parse(payload: op.payload) { return true }
        return false
    }
}
