import Foundation
import SrokaCore
import SrokaDatabase
import Testing

@testable import SrokaSync

/// Port of Android `LibraryRepositoryTest`.
struct LibraryRepositoryTests {
    @Test func `Save creates a pending item and an add op`() async throws {
        let h = try Harness()
        let result = await h.library.save(
            url: "https://Example.com/post?utm_source=x", title: "Hi", tags: [" travel ", "Travel", "food"],
            source: .manual)
        guard case .saved(let id, let alreadySaved) = result else {
            Issue.record("expected saved, got \(result)")
            return
        }
        #expect(!alreadySaved)
        let item = try #require(await first(h.library.observeItem(id: id)) ?? nil)
        #expect(item.canonicalUrl == "https://example.com/post")
        #expect(item.parseStatus == .pending)
        #expect(item.tags == ["food", "travel"])
        let ops = try await h.queuedOps()
        guard ops.count == 1, case .add(let add) = ops[0] else {
            Issue.record("expected one add, got \(ops)")
            return
        }
        #expect(add.itemId == id)
        #expect(add.tags == ["travel", "food"])
        #expect(add.source == ItemSource(wire: "web"))
        #expect(try await h.queued().first?.payload.contains("\"onDuplicate\":\"readd\"") == true)
        #expect(h.controller.syncRequests == 1)
    }

    @Test func `Saving the same canonical URL re-adds the existing item`() async throws {
        let h = try Harness()
        let firstId = try await h.savedId("https://example.com/a")
        await h.library.setStatus(id: firstId, status: .archived)
        h.time.advance(1_000)

        let second = await h.library.save(url: "https://example.com/a#frag", title: nil, tags: ["x"], source: .share)

        #expect(second == .saved(itemId: firstId, alreadySaved: true))
        let item = try #require(try await h.item(firstId))
        #expect(item.status == .unread)
        #expect(item.savedAt == h.now)
        #expect(try await h.tagNames(firstId) == ["x"])
        #expect(
            try await h.queued().map(\.type) == [
                WireOp.Kind.add.rawValue, WireOp.Kind.setStatus.rawValue, WireOp.Kind.add.rawValue,
            ])
    }

    @Test func `An overlong title is truncated locally and on the wire`() async throws {
        let h = try Harness()
        let id = try await h.savedId("https://example.com/t", title: String(repeating: "x", count: 1_500))
        #expect(try await h.item(id)?.title?.count == 1_000)
        guard case .add(let add) = try await h.queuedOps().first else {
            Issue.record("expected an add")
            return
        }
        #expect(add.title?.count == 1_000)
        let payload = try #require(try await h.queued().first?.payload)
        #expect(payload.contains(String(repeating: "x", count: 1_000)))
        #expect(!payload.contains(String(repeating: "x", count: 1_001)))

        await h.library.setTitle(id: id, title: "  " + String(repeating: "y", count: 2_000))
        #expect(try await h.item(id)?.title == String(repeating: "y", count: 1_000))
        guard case .setTitle(let setTitle) = try await h.queuedOps().last else {
            Issue.record("expected a setTitle")
            return
        }
        #expect(setTitle.title == String(repeating: "y", count: 1_000))
    }

    @Test func `An overlong URL is invalid`() async throws {
        let h = try Harness()
        let result = await h.library.save(
            url: "https://example.com/" + String(repeating: "a", count: 4_100), title: nil, tags: [], source: .share)
        #expect(result == .invalidUrl)
        #expect(try await h.pendingCount() == 0)
        #expect(h.controller.syncRequests == 0)
    }

    @Test func `A string that is not a URL is invalid`() async throws {
        let h = try Harness()
        #expect(await h.library.save(url: "not a url", title: nil, tags: [], source: .share) == .invalidUrl)
        #expect(try await h.pendingCount() == 0)
    }

    @Test func `Progress, status, favorite and title coalesce`() async throws {
        let h = try Harness()
        try await h.insert("a")
        for step in 0..<3 { await h.library.setProgress(id: "a", progress: Double(step) / 10, anchor: step) }
        await h.library.setFavorite(id: "a", favorite: true)
        await h.library.setFavorite(id: "a", favorite: false)
        await h.library.setStatus(id: "a", status: .archived)
        await h.library.setStatus(id: "a", status: .unread)
        await h.library.setTitle(id: "a", title: "x")
        await h.library.setTitle(id: "a", title: " ")

        let ops = try await h.queuedOps()
        #expect(ops.count == 4)
        for op in ops {
            switch op {
            case .setProgress(let op): #expect(op.progress == 0.2)
            case .setFavorite(let op): #expect(!op.value)
            case .setStatus(let op): #expect(op.status == .unread)
            case .setTitle(let op): #expect(op.title == nil)
            default: Issue.record("unexpected op \(op)")
            }
        }
    }

    @Test func `Tag ops are never coalesced`() async throws {
        let h = try Harness()
        try await h.insert("a", tags: ["Old", "keep"])
        await h.library.setTags(id: "a", names: ["keep", "New"])
        await h.library.setTags(id: "a", names: ["keep"])

        let ops = try await h.queuedOps().compactMap { op -> String? in
            guard case .tag(let tag) = op else { return nil }
            return "\(tag.tag)/\(tag.present)"
        }
        #expect(ops == ["Old/false", "New/true", "New/false"])
        #expect(try await h.tagNames("a") == ["keep"])
    }

    @Test func `Archive sets archivedAt and a missing item is a no-op`() async throws {
        let h = try Harness()
        try await h.insert("a")
        await h.library.setStatus(id: "a", status: .archived)
        #expect(try await h.item("a")?.archivedAt == h.now)
        await h.library.setFavorite(id: "missing", favorite: true)
        #expect(try await h.pendingCount() == 1)
        #expect(h.controller.syncRequests == 1)
    }

    @Test func `Delete removes the row and the files`() async throws {
        let h = try Harness()
        try await h.insert("a")
        await h.library.delete(id: "a")
        #expect(try await h.item("a") == nil)
        #expect(h.hooks.deleted == ["a"])
        #expect(try await h.queued().map(\.type) == [WireOp.Kind.delete.rawValue])
    }

    @Test func `Tag rename and delete`() async throws {
        let h = try Harness()
        try await h.insert("a", tags: ["ml"])
        let b = Harness.entity("b")
        try await h.db.write { db in try ItemDao.upsert(db, b, tags: ["ML", "x"]) }

        #expect(await h.tags.rename(from: "ml", to: "  ") == .invalidName)
        #expect(await h.tags.rename(from: "ml", to: "machine-learning") == .done)
        #expect(try await h.tagNames("a") == ["machine-learning"])
        #expect(try await h.tagNames("b") == ["machine-learning", "x"])
        await h.tags.delete(name: "x")
        #expect(try await h.tagNames("b") == ["machine-learning"])
        let queued = try await h.queued()
        #expect(queued.map(\.type) == [WireOp.Kind.tagRename.rawValue, WireOp.Kind.tagDelete.rawValue])
        #expect(queued.first?.itemId == nil)
    }

    @Test func `Set tags on a missing item queues nothing`() async throws {
        let h = try Harness()
        await h.library.setTags(id: "missing", names: ["a"])
        #expect(try await h.pendingCount() == 0)
        #expect(h.controller.syncRequests == 0)
    }

    @Test func `Progress is clamped and NaN becomes zero`() async throws {
        let h = try Harness()
        try await h.insert("a")
        await h.library.setProgress(id: "a", progress: .nan, anchor: nil)
        #expect(try await h.item("a")?.progress == 0)
        await h.library.setProgress(id: "a", progress: 3, anchor: nil)
        #expect(try await h.item("a")?.progress == 1)
    }
}

/// The first value of a stream.
func first<T: Sendable>(_ stream: AsyncStream<T>) async -> T? {
    for await value in stream { return value }
    return nil
}
