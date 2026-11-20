import Foundation
import GRDB
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import Synchronization
import Testing

@testable import SrokaSync

/// The app and the share extension write one database file at the same time. Two `AppDatabase` handles on one
/// file (app: `openShared`, extension: `openForExtension`), each with its own `OpClock`, stand in for the two
/// processes; they share only what the processes share: the file and the clock store beside it.
struct CrossProcessTests {
    /// One process's view of the shared library.
    struct Process {
        let database: AppDatabase
        let writer: OpWriter
        let engine: SyncEngine
    }

    /// A temporary database directory, removed when the test ends.
    final class SharedFile: Sendable {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sroka-xproc-\(UUID().uuidString)")
        var url: URL { directory.appending(path: AppDatabase.fileName) }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// `/v1/sync/push` with the server's idempotency on `(deviceId, opId)`: a re-sent op is reported applied again.
    final class IdempotentServer: Sendable {
        private let state = Mutex((applied: [String](), sent: [String]()))
        var applied: [String] { state.withLock { $0.applied } }
        var sent: [String] { state.withLock { $0.sent } }

        func reply(to payloads: [String]) -> FakeSyncAPI.Reply {
            let ids = payloads.compactMap(opId)
            state.withLock { state in
                state.sent += ids
                for id in ids where !state.applied.contains(id) { state.applied.append(id) }
            }
            return .json(pushJson(applied: ids, cursor: 1))
        }
    }

    let file = SharedFile()
    let api = FakeSyncAPI()
    let session = FakeSession()
    /// Both processes read the same wall clock: every tick lands in the same millisecond.
    let now: @Sendable () -> Int64 = { 1_700_000_000_000 }

    func process(extension isExtension: Bool) throws -> Process {
        let database =
            try isExtension ? AppDatabase.openForExtension(at: file.url) : AppDatabase.openShared(at: file.url)
        let clock = OpClock(now: now, store: FileOpClockStore(besideDatabaseAt: file.url))
        return Process(
            database: database,
            writer: OpWriter(database: database, opClock: clock, now: now),
            engine: SyncEngine(database: database, api: api, session: session, now: now)
        )
    }

    func insertItem(_ id: String, into database: AppDatabase) async throws {
        let record = Harness.entity(id)
        try await database.write { db in try ItemDao.upsert(db, record) }
    }

    func queued(_ database: AppDatabase) async throws -> [PendingOpRecord] {
        try await database.read { db in try PendingOpDao.all(db) }
    }

    @Test func `Two processes never issue the same op time and times follow commit order`() async throws {
        let app = try process(extension: false)
        let share = try process(extension: true)
        try await insertItem("a", into: app.database)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                let writer = index.isMultiple(of: 2) ? app.writer : share.writer
                group.addTask {
                    try await writer.write { _, context in
                        [
                            .tag(
                                .init(
                                    opId: context.newId(), itemId: "a", at: context.at, tag: "t\(index)", present: true)
                            )
                        ]
                    }
                }
            }
            try await group.waitForAll()
        }

        let ops = try await queued(app.database)
        let times = ops.compactMap { at(of: $0.payload) }
        #expect(ops.count == 40)
        #expect(Set(ops.map(\.opId)).count == 40)
        #expect(times.count == 40)
        #expect(times == times.sorted() && Set(times).count == times.count)
    }

    @Test func `A later edit in the other process gets a later time than an earlier one`() async throws {
        let app = try process(extension: false)
        let share = try process(extension: true)
        try await insertItem("a", into: app.database)

        // The app's clock is created first and has cached its start value; the extension then writes.
        try await share.writer.write { _, context in
            [.setFavorite(.init(opId: context.newId(), itemId: "a", at: context.at, value: true))]
        }
        let first = try #require(try await queued(app.database).first.flatMap { at(of: $0.payload) })
        try await app.writer.write { _, context in
            [.setFavorite(.init(opId: context.newId(), itemId: "a", at: context.at, value: false))]
        }
        let second = try #require(try await queued(app.database).first.flatMap { at(of: $0.payload) })
        #expect(second > first)
    }

    @Test func `Concurrent pushes from both processes neither lose nor duplicate an op`() async throws {
        let app = try process(extension: false)
        let share = try process(extension: true)
        let server = IdempotentServer()
        try await insertItem("a", into: app.database)
        try await share.writer.write { _, context in
            [.setFavorite(.init(opId: context.newId(), itemId: "a", at: context.at, value: true))]
        }
        let firstOp = try #require(try await queued(app.database).first?.opId)

        // While the extension's push is in flight, the app edits the same field: the queued op is coalesced away
        // and replaced by a newer one, which the extension's acknowledgement must not delete.
        let edited = Mutex(false)
        let appWriter = app.writer
        api.serve { call in
            guard case .push(let payloads) = call else { throw ApiError.invalidRequest }
            if !edited.withLock({ $0 }) {
                edited.withLock { $0 = true }
                try await appWriter.write { _, context in
                    [.setFavorite(.init(opId: context.newId(), itemId: "a", at: context.at, value: false))]
                }
            }
            return server.reply(to: payloads)
        }
        #expect(await share.engine.pushOnce() == .success(pulledItems: 0))
        let remaining = try await queued(app.database)
        #expect(remaining.count == 1)
        let secondOp = try #require(remaining.first?.opId)
        #expect(secondOp != firstOp)

        // Both processes push at once: the op may go out twice, the server applies it once, nothing stays queued.
        async let fromApp = app.engine.pushOnce()
        async let fromShare = share.engine.pushOnce()
        _ = await (fromApp, fromShare)
        #expect(try await queued(app.database).isEmpty)
        #expect(try await queued(share.database).isEmpty)
        #expect(server.applied == [firstOp, secondOp])
        let favorite = try await app.database.read { db in try ItemDao.item(db, id: "a")?.isFavorite }
        #expect(favorite == false)
    }
}

private func field(_ name: String, of payload: String) -> Any? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
        return nil
    }
    return object[name]
}

private func opId(_ payload: String) -> String? { field("opId", of: payload) as? String }

private func at(of payload: String) -> Int64? { (field("at", of: payload) as? NSNumber)?.int64Value }
