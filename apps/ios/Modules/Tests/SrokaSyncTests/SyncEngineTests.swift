import Foundation
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import Synchronization
import Testing

@testable import SrokaSync

/// Port of Android `SyncEngineTest`.
struct SyncEngineTests {
    @Test func `Applied push removes the ops, then the pull updates the item`() async throws {
        let h = try Harness()
        let id = try await h.savedId("https://example.com/a")
        let op = try #require(try await h.queued().first)
        h.api.enqueue(pushJson(applied: [op.opId], cursor: 5))
        h.api.enqueue(pullJson(5, items: [itemJson(id, seq: 5, title: "Parsed")]))

        #expect(await h.engine.sync() == .success(pulledItems: 1))

        let payload = try #require(h.api.pushes.first?.first)
        #expect(payload.contains("\"opId\":\"\(op.opId)\""))
        #expect(payload.contains("\"type\":\"item.add\""))
        #expect(payload.contains("\"itemId\":\"\(id)\""))
        #expect(h.api.pulls == [.pull(cursor: 0, full: true)])
        #expect(try await h.pendingCount() == 0)
        #expect(try await h.item(id)?.title == "Parsed")
        let state = try await h.syncState()
        #expect(state.cursor == 5)
        #expect(state.lastSuccessAt == h.now)
        #expect(state.lastError == nil)
    }

    @Test func `An item_deleted rejection removes the local item`() async throws {
        let h = try Harness()
        try await h.insert("a")
        await h.library.setFavorite(id: "a", favorite: true)
        await h.library.setStatus(id: "a", status: .archived)
        let ops = try await h.queued().map(\.opId)
        h.api.enqueue(pushJson(rejected: [(ops[0], "item_deleted"), (ops[1], "item_deleted")], cursor: 1))
        h.api.enqueue(pullJson(1))

        _ = await h.engine.sync()

        #expect(try await h.item("a") == nil)
        #expect(try await h.pendingCount() == 0)
        #expect(h.hooks.deleted.contains("a"))
    }

    @Test func `Other rejections only drop the op`() async throws {
        let h = try Harness()
        try await h.insert("a")
        await h.library.setFavorite(id: "a", favorite: true)
        let op = try #require(try await h.queued().first).opId
        h.api.enqueue(pushJson(rejected: [(op, "unknown_item")], cursor: 1))
        h.api.enqueue(pullJson(1))

        _ = await h.engine.sync()

        #expect(try await h.item("a") != nil)
        #expect(try await h.pendingCount() == 0)
    }

    @Test func `Aliases re-target queued ops and drop the client row`() async throws {
        let h = try Harness()
        let client = try await h.savedId("https://example.com/dup")
        let addOp = try #require(try await h.queued().first).opId
        try await h.enqueue(.setFavorite(.init(opId: "later", itemId: client, at: h.now, value: true)))
        h.api.enqueue(pushJson(applied: [addOp], aliases: [client: "server-1"], cursor: 3))
        h.api.enqueue(status: 503)

        #expect(await h.engine.sync() == .failure(.server))

        #expect(try await h.item(client) == nil)
        let queued = try await h.queued()
        #expect(queued.count == 1)
        #expect(queued.first?.itemId == "server-1")
        #expect(queued.first?.payload.contains("\"itemId\":\"server-1\"") == true)
        #expect(h.api.pushes.count == 2)
    }

    @Test func `An alias whose canonical row is local merges into it`() async throws {
        let h = try Harness()
        try await h.insert("server-2")
        let client = try await h.savedId("https://example.com/other")
        let addOp = try #require(try await h.queued().first).opId
        h.api.enqueue(pushJson(applied: [addOp], aliases: [client: "server-2"], cursor: 3))
        h.api.enqueue(pullJson(3))

        #expect(await h.engine.sync() == .success(pulledItems: 0))

        #expect(try await h.item(client) == nil)
        #expect(try await h.item("server-2")?.url == "https://example.com/server-2")
        #expect(h.hooks.deleted.contains(client))
    }

    @Test func `A rejected add removes a local-only orphan but keeps server rows`() async throws {
        let h = try Harness()
        let orphan = try await h.savedId("https://example.com/o")
        await h.library.setFavorite(id: orphan, favorite: true)
        try await h.insert("known")
        let add = try #require(try await h.queued().first { $0.type == WireOp.Kind.add.rawValue }).opId
        h.api.enqueue(pushJson(rejected: [(add, "invalid_op")], cursor: 1))
        h.api.enqueue(pullJson(1))

        _ = await h.engine.sync()

        #expect(try await h.item(orphan) == nil)
        #expect(try await h.pendingCount() == 0)
        #expect(try await h.item("known") != nil)
    }

    @Test func `A rejected add of a server-known item keeps the row`() async throws {
        let h = try Harness()
        try await h.insert("known")
        try await h.enqueue(
            .add(.init(opId: "op-add", itemId: "known", at: h.now, url: "https://example.com/known", savedAt: h.now)))
        h.api.enqueue(pushJson(rejected: [("op-add", "invalid_op")], cursor: 1))
        h.api.enqueue(pullJson(1))

        _ = await h.engine.sync()

        #expect(try await h.item("known") != nil)
    }

    @Test func `A re-save after a remote delete re-keys the add on item_deleted`() async throws {
        let h = try Harness()
        try await h.insert("y")
        let saved = await h.library.save(url: "https://example.com/y", title: nil, tags: ["t"], source: .share)
        #expect(saved == .saved(itemId: "y", alreadySaved: true))
        await h.library.setFavorite(id: "y", favorite: true)
        let ops = try await h.queued()
        let addId = ops[0].opId
        h.api.enqueue(pushJson(rejected: [(addId, "item_deleted"), (ops[1].opId, "item_deleted")], cursor: 1))
        h.api.enqueue(status: 503)

        _ = await h.engine.sync()

        #expect(try await h.item("y") == nil)
        let queued = try await h.queued()
        #expect(queued.map(\.type) == [WireOp.Kind.add.rawValue, WireOp.Kind.setFavorite.rawValue])
        let newId = try #require(queued.first?.itemId)
        #expect(newId != "y")
        #expect(queued[1].itemId == newId)
        #expect(queued[0].opId != addId)
        #expect(queued[0].payload.contains("\"opId\":\"\(queued[0].opId)\""))
        #expect(queued[0].payload.contains("\"itemId\":\"\(newId)\""))
        #expect(try await h.item(newId)?.isFavorite == true)
        #expect(try await h.tagNames(newId) == ["t"])
        let second = try #require(h.api.pushes.last)
        #expect(h.api.pushes.count == 2)
        #expect(second.allSatisfy { $0.contains("\"itemId\":\"\(newId)\"") })
    }

    @Test func `A second answer for the same batch leaves the re-keyed ops queued`() async throws {
        // The app and the share extension pushed the same batch; both answers say item_deleted.
        let h = try Harness()
        try await h.insert("y")
        _ = await h.library.save(url: "https://example.com/y", title: nil, tags: [], source: .share)
        await h.library.setFavorite(id: "y", favorite: true)
        let batch = try await h.queued()
        let json = pushJson(rejected: batch.map { ($0.opId, "item_deleted") }, cursor: 1)
        let response = try JSONDecoder().decode(PushResponseDto.self, from: Data(json.utf8))
        let now = h.now

        for _ in 0..<2 {
            _ = try await h.db.write { db in
                try SyncTransactions.applyPushResponse(db, batch: batch, response: response, now: now)
            }
        }

        let queued = try await h.queued()
        #expect(queued.map(\.type) == [WireOp.Kind.add.rawValue, WireOp.Kind.setFavorite.rawValue])
        let newId = try #require(queued.first?.itemId)
        #expect(newId != "y" && queued[1].itemId == newId)
        #expect(try await h.item(newId)?.isFavorite == true)
    }

    @Test func `A re-save while the tombstone pulls in re-keys the pending add`() async throws {
        let h = try Harness()
        try await h.insert("y")
        let library = h.library
        h.api.serve { call in
            guard call.isPull else { return .json(pushJson(cursor: 2)) }
            _ = await library.save(url: "https://example.com/y", title: nil, tags: [], source: .share)
            return .json(pullJson(2, deletedItems: ["y"]))
        }

        #expect(await h.engine.sync() == .success(pulledItems: 0))

        #expect(try await h.item("y") == nil)
        let queued = try await h.queued()
        #expect(queued.count == 1)
        #expect(queued.first?.type == WireOp.Kind.add.rawValue)
        let newId = try #require(queued.first?.itemId)
        #expect(newId != "y")
        #expect(try await h.item(newId) != nil)
        #expect(queued.first?.payload.contains("\"itemId\":\"\(newId)\"") == true)
    }

    @Test func `An alias keeps the saved item when the pull fails`() async throws {
        let h = try Harness()
        let client = try await h.savedId("https://example.com/dup2")
        let addOp = try #require(try await h.queued().first).opId
        h.api.enqueue(pushJson(applied: [addOp], aliases: [client: "server-9"], cursor: 3))
        h.api.enqueue(status: 503)

        #expect(await h.engine.sync() == .failure(.server))

        #expect(try await h.item(client) == nil)
        #expect(try await h.item("server-9")?.url == "https://example.com/dup2")
        await h.library.setFavorite(id: "server-9", favorite: true)
        #expect(try await h.pendingCount() == 1)
    }

    @Test func `A pending tag rename survives a page that carries only tags`() async throws {
        let h = try Harness()
        try await h.insert("a", tags: ["ml"])
        let tags = h.tags
        h.api.serve { call in
            guard call.isPull else { return .json(pushJson(cursor: 5)) }
            _ = await tags.rename(from: "ml", to: "machine-learning")
            return .json(pullJson(5, tags: "{\"id\":\"t1\",\"name\":\"ml\",\"seq\":5}"))
        }

        _ = await h.engine.sync()

        #expect(try await h.tagNames("a") == ["machine-learning"])
        let rows = try await h.db.read { db in try TagDao.allRows(db) }
        #expect(!rows.contains { $0.nameKey == "ml" })
    }

    @Test func `A pull from zero is full and never gets 410 after the horizon`() async throws {
        let h = try Harness()
        try await h.updateSyncState { $0.cursor = 5 }
        try await h.insert("stale")
        h.api.serve { call in
            guard case .pull(let cursor, let full) = call else { return .json(pushJson(cursor: 0)) }
            if !full, (1..<100).contains(cursor) {
                return .error(.http(status: 410, code: "resync_required", message: nil, retryAfter: nil))
            }
            if cursor == 0 { return .json(pullJson(50, items: [itemJson("a", seq: 50)], hasMore: true)) }
            return .json(pullJson(120, items: [itemJson("b", seq: 120)]))
        }

        #expect(await h.engine.sync() == .success(pulledItems: 2))

        #expect(
            h.api.pulls == [.pull(cursor: 5, full: false), .pull(cursor: 0, full: true), .pull(cursor: 50, full: true)])
        let state = try await h.syncState()
        #expect(state.cursor == 120)
        #expect(!state.fullResync)
        #expect(try await h.item("stale") == nil)
        #expect(try await h.item("a") != nil)

        h.api.serve { _ in .json(pullJson(121)) }
        _ = await h.engine.sync()
        #expect(h.api.pulls.last == .pull(cursor: 120, full: false))
    }

    @Test func `The first sync from zero uses a full pass`() async throws {
        let h = try Harness()
        h.api.serve { call in
            guard case .pull(let cursor, _) = call else { return .json(pushJson(cursor: 0)) }
            if cursor == 0 { return .json(pullJson(10, items: [itemJson("a", seq: 10)], hasMore: true)) }
            return .json(pullJson(20, items: [itemJson("b", seq: 20)]))
        }

        #expect(await h.engine.sync() == .success(pulledItems: 2))

        #expect(h.api.pulls == [.pull(cursor: 0, full: true), .pull(cursor: 10, full: true)])
        #expect(try await !h.syncState().fullResync)
    }

    @Test func `Unsafe server ids never reach the disk or the database`() async throws {
        let h = try Harness()
        try await h.insert("a")
        h.api.serve { _ in
            .json(
                pullJson(
                    5, items: [itemJson("../datastore", seq: 5), itemJson("b", seq: 5)],
                    deletedItems: ["..", "../x", "a"]))
        }

        _ = await h.engine.sync()

        #expect(try await h.item("../datastore") == nil)
        #expect(try await h.item("b") != nil)
        #expect(try await h.item("a") == nil)
        #expect(h.hooks.deleted.allSatisfy(isValidItemId))
        #expect(h.hooks.deleted.contains("a"))
    }

    @Test func `Pull pages advance the cursor per page atomically`() async throws {
        let h = try Harness()
        h.api.enqueue(
            pullJson(
                10, items: [itemJson("a", seq: 10, tags: ["x"])], hasMore: true,
                tags: "{\"id\":\"t1\",\"name\":\"x\",\"seq\":10}"))
        h.api.enqueue(pullJson(20, items: [itemJson("b", seq: 20)], hasMore: true))
        h.api.enqueue(status: 500)

        #expect(await h.engine.sync() == .failure(.server))

        var state = try await h.syncState()
        #expect(state.cursor == 20)
        #expect(state.lastError == SyncErrorKind.server.rawValue)
        #expect(try await h.tagNames("a") == ["x"])
        #expect(try await h.item("b") != nil)
        #expect(
            h.api.pulls == [.pull(cursor: 0, full: true), .pull(cursor: 10, full: true), .pull(cursor: 20, full: true)])

        h.api.enqueue(pullJson(30, items: [itemJson("c", seq: 30)], deletedItems: ["a"]))
        #expect(await h.engine.sync() == .success(pulledItems: 1))
        #expect(try await h.item("a") == nil)
        state = try await h.syncState()
        #expect(state.cursor == 30)
        #expect(state.lastError == nil)
    }

    @Test func `Rebase keeps unpushed local edits`() async throws {
        let h = try Harness()
        try await h.insert("a")
        let library = h.library
        h.api.serve { call in
            guard call.isPull else { return .json(pushJson(cursor: 1)) }
            await library.setStatus(id: "a", status: .archived)
            await library.setFavorite(id: "a", favorite: true)
            await library.setProgress(id: "a", progress: 0.7, anchor: 3)
            await library.setTags(id: "a", names: ["local"])
            return .json(
                pullJson(
                    1, items: [itemJson("a", seq: 1, status: "unread", favorite: false, progress: 0.1, tags: ["srv"])]))
        }

        #expect(await h.engine.sync() == .success(pulledItems: 1))

        let item = try #require(try await h.item("a"))
        #expect(item.status == .archived)
        #expect(item.isFavorite)
        #expect(item.progress == 0.7)
        #expect(item.progressAnchor == 3)
        #expect(try await h.tagNames("a") == ["local", "srv"])
        #expect(item.serverSeq == 1)
        #expect(try await h.pendingCount() == 4)
    }

    @Test func `A 410 resync deletes vanished items but keeps ones with pending ops`() async throws {
        let h = try Harness()
        try await h.updateSyncState { $0.cursor = 50 }
        try await h.insert("kept")
        try await h.insert("gone")
        try await h.insert("local")
        let library = h.library
        h.api.serve { call in
            guard case .pull(let cursor, _) = call else { return .json(pushJson(cursor: 60)) }
            if cursor == 50 {
                return .error(.http(status: 410, code: "resync_required", message: nil, retryAfter: nil))
            }
            await library.setFavorite(id: "local", favorite: true)
            return .json(pullJson(60, items: [itemJson("kept", seq: 60)]))
        }

        #expect(await h.engine.sync() == .success(pulledItems: 1))

        #expect(try await h.item("kept") != nil)
        #expect(try await h.item("local") != nil)
        #expect(try await h.item("gone") == nil)
        #expect(h.hooks.deleted == ["gone"])
        let state = try await h.syncState()
        #expect(!state.fullResync)
        #expect(state.cursor == 60)
        #expect(try await h.item("kept")?.resyncMark == 0)
        #expect(try await h.item("local")?.resyncMark == 0)
    }

    @Test func `A second 410 in one pass fails instead of looping`() async throws {
        let h = try Harness()
        try await h.updateSyncState { $0.cursor = 50 }
        h.api.serve { _ in .error(.http(status: 410, code: "resync_required", message: nil, retryAfter: nil)) }

        #expect(await h.engine.sync() == .failure(.server))
        #expect(h.api.pulls.count == 2)
    }

    @Test func `Unauthorized marks the session expired and keeps data`() async throws {
        let h = try Harness()
        try await h.insert("a")
        await h.library.setFavorite(id: "a", favorite: true)
        h.api.enqueue(status: 401, code: "unauthorized")

        #expect(await h.engine.sync() == .failure(.auth))

        #expect(h.session.state == .expired(email: "reader@example.com"))
        #expect(try await h.pendingCount() == 1)
        #expect(try await h.item("a") != nil)
        let op = try #require(try await h.queued().first)
        #expect(op.lastError == "http_401")
        #expect(try await h.syncState().lastError == SyncErrorKind.auth.rawValue)
    }

    @Test func `A network failure keeps the queue and records nothing on the ops`() async throws {
        let h = try Harness()
        try await h.insert("a")
        await h.library.setFavorite(id: "a", favorite: true)
        h.api.enqueue(error: .transport(.notConnectedToInternet))

        #expect(await h.engine.sync() == .failure(.network))

        let op = try #require(try await h.queued().first)
        #expect(op.attempts == 0)
        #expect(op.lastError == nil)
        #expect(h.session.state == .signedIn(email: "reader@example.com"))
    }

    @Test func `A server error records http_N on the attempted ops`() async throws {
        let h = try Harness()
        try await h.insert("a")
        await h.library.setFavorite(id: "a", favorite: true)
        h.api.enqueue(status: 503)

        #expect(await h.engine.sync() == .failure(.server))

        let op = try #require(try await h.queued().first)
        #expect(op.attempts == 1)
        #expect(op.lastError == "http_503")
    }

    @Test func `Pushes go in batches of at most 500 and never empty`() async throws {
        let h = try Harness()
        let ids = (0..<501).map { "op-\(String(format: "%04d", $0))" }
        try await h.db.write { db in
            for (index, id) in ids.enumerated() {
                let op = WireOp.setFavorite(.init(opId: id, itemId: "i\(index)", at: Int64(index), value: true))
                _ = try PendingOpDao.enqueue(db, op.pendingRecord(createdAt: Int64(index)))
            }
        }
        h.api.serve { call in
            guard case .push(let payloads) = call else { return .json(pullJson(1)) }
            let applied = payloads.compactMap { WireOp.parse(payload: $0)?.opId }
            return .json(pushJson(applied: applied, cursor: 1))
        }

        #expect(await h.engine.sync() == .success(pulledItems: 0))

        #expect(h.api.pushes.map(\.count) == [500, 1])
        #expect(try await h.pendingCount() == 0)
    }

    @Test func `Corrupt queued payloads are dropped without being sent`() async throws {
        let h = try Harness()
        try await h.db.write { db in
            _ = try PendingOpDao.enqueue(
                db, PendingOpRecord(opId: "bad", itemId: "a", type: "item.setFavorite", payload: "[1]", createdAt: 1))
        }
        h.api.enqueue(pullJson(1))

        #expect(await h.engine.sync() == .success(pulledItems: 0))
        #expect(h.api.pushes.isEmpty)
        #expect(try await h.pendingCount() == 0)
    }

    @Test func `A push nobody acknowledges fails and keeps the ops`() async throws {
        let h = try Harness()
        try await h.insert("a")
        await h.library.setFavorite(id: "a", favorite: true)
        h.api.enqueue(pushJson(cursor: 1))

        #expect(await h.engine.sync() == .failure(.server))

        let op = try #require(try await h.queued().first)
        #expect(op.lastError == "not_acknowledged")
        #expect(h.api.pulls.isEmpty)
    }

    @Test func `A signed-out session skips the pass`() async throws {
        let h = try Harness()
        h.session.set(.signedOut)

        #expect(await h.engine.sync() == .skipped)
        #expect(h.api.calls.isEmpty)
    }

    @Test func `pushOnce sends one batch and does not pull or record`() async throws {
        let h = try Harness()
        try await h.insert("a")
        await h.library.setFavorite(id: "a", favorite: true)
        let op = try #require(try await h.queued().first).opId
        h.api.enqueue(pushJson(applied: [op], cursor: 1))

        #expect(await h.engine.pushOnce() == .success(pulledItems: 0))

        #expect(h.api.pulls.isEmpty)
        #expect(try await h.pendingCount() == 0)
        #expect(try await h.syncState().lastSuccessAt == nil)
    }

    @Test func `Concurrent passes run one at a time`() async throws {
        let h = try Harness()
        let active = Mutex((now: 0, peak: 0))
        h.api.serve { _ in
            active.withLock { state in
                state.now += 1
                state.peak = max(state.peak, state.now)
            }
            try await Task.sleep(for: .milliseconds(20))
            active.withLock { $0.now -= 1 }
            return .json(pullJson(1))
        }
        let engine = h.engine

        await withTaskGroup(of: SyncOutcome.self) { group in
            for _ in 0..<3 { group.addTask { await engine.sync() } }
            for await outcome in group { #expect(outcome == .success(pulledItems: 0)) }
        }

        #expect(active.withLock { $0.peak } == 1)
        #expect(h.api.pulls.count == 3)
    }

    @Test func `Wipe waits for the running pass, cancels it and runs alone`() async throws {
        let h = try Harness()
        let gate = Gate()
        let log = Mutex<[String]>([])
        h.api.serve { _ in
            log.withLock { $0.append("pull started") }
            await gate.wait()
            log.withLock { $0.append("pull ended") }
            try Task.checkCancellation()
            return .json(pullJson(7, items: [itemJson("late", seq: 7)]))
        }
        let engine = h.engine
        let pass = Task { await engine.sync() }
        await eventually { log.withLock { $0.count } == 1 }

        let wipe = Task {
            try await engine.wipe {
                log.withLock { $0.append("wipe") }
                try await h.db.write { db in
                    try PendingOpDao.deleteAll(db)
                    try SyncStateDao.deleteAll(db)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(log.withLock { $0 } == ["pull started"])
        await gate.open()

        #expect(await pass.value == .cancelled)
        try await wipe.value
        #expect(log.withLock { $0 } == ["pull started", "pull ended", "wipe"])
        #expect(try await h.item("late") == nil)
        #expect(try await h.syncState().cursor == 0)
    }
}

/// A one-shot latch for holding a fake server reply.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
