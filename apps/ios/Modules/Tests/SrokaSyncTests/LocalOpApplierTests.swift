import Foundation
import SrokaCore
import SrokaDatabase
import Testing

@testable import SrokaSync

/// Port of Android `LocalOpApplier` rules.
struct LocalOpApplierTests {
    private func apply(_ h: Harness, _ op: WireOp) async throws -> Bool {
        try await h.db.write { db in try LocalOpApplier.apply(db, op) }
    }

    @Test func `An add creates a pending unread item with united tags`() async throws {
        let h = try Harness()
        let add = WireOp.add(
            .init(
                opId: "o1", itemId: "n", at: 5, url: "https://Example.com/x?utm_source=y", title: "T",
                tags: ["a", "A", " ", "b"], source: ItemSource(wire: "web"), savedAt: 4))
        #expect(try await apply(h, add))

        let item = try #require(try await h.item("n"))
        #expect(item.canonicalUrl == "https://example.com/x")
        #expect(item.parseStatus == .pending)
        #expect(item.status == .unread)
        #expect(item.savedAt == 4)
        #expect(item.title == "T")
        #expect(item.source == "web")
        #expect(try await h.tagNames("n") == ["a", "b"])
    }

    @Test func `An add with a URL that does not normalise changes nothing`() async throws {
        let h = try Harness()
        #expect(try await !apply(h, .add(.init(opId: "o", itemId: "n", at: 1, url: "not a url"))))
        #expect(try await h.item("n") == nil)
    }

    @Test func `A re-add unarchives, keeps the title, takes the later savedAt and unites tags`() async throws {
        let h = try Harness()
        try await h.insert("a", tags: ["old"])
        _ = try await apply(h, .setStatus(.init(opId: "s", itemId: "a", at: 10, status: .archived)))
        #expect(try await h.item("a")?.archivedAt == 10)

        _ = try await apply(
            h,
            .add(
                .init(
                    opId: "o", itemId: "a", at: 2_000, url: "https://example.com/a", title: "New", tags: ["OLD", "new"])
            ))

        let item = try #require(try await h.item("a"))
        #expect(item.status == .unread)
        #expect(item.archivedAt == nil)
        #expect(item.savedAt == 2_000)
        #expect(item.title == "Title a")
        #expect(try await h.tagNames("a") == ["new", "old"])

        _ = try await apply(
            h, .add(.init(opId: "p", itemId: "a", at: 3_000, url: "https://example.com/a", savedAt: 1_500)))
        #expect(try await h.item("a")?.savedAt == 2_000)
    }

    @Test func `Item ops on a missing item report no change`() async throws {
        let h = try Harness()
        let ops: [WireOp] = [
            .setStatus(.init(opId: "1", itemId: "m", at: 1, status: .archived)),
            .setFavorite(.init(opId: "2", itemId: "m", at: 1, value: true)),
            .setProgress(.init(opId: "3", itemId: "m", at: 1, progress: 0.5)),
            .setTitle(.init(opId: "4", itemId: "m", at: 1, title: "x")),
            .tag(.init(opId: "5", itemId: "m", at: 1, tag: "x", present: true)),
            .delete(.init(opId: "6", itemId: "m", at: 1)),
            .refresh(.init(opId: "7", itemId: "m", at: 1)),
        ]
        for op in ops { #expect(try await !apply(h, op)) }
    }

    @Test func `Progress, favorite, title, refresh and delete update the row`() async throws {
        let h = try Harness()
        try await h.insert("a")
        _ = try await apply(h, .setProgress(.init(opId: "1", itemId: "a", at: 77, progress: 0.4, anchor: 9)))
        _ = try await apply(h, .setFavorite(.init(opId: "2", itemId: "a", at: 1, value: true)))
        _ = try await apply(h, .setTitle(.init(opId: "3", itemId: "a", at: 1, title: nil)))
        _ = try await apply(h, .refresh(.init(opId: "4", itemId: "a", at: 1)))

        let item = try #require(try await h.item("a"))
        #expect(item.progress == 0.4)
        #expect(item.progressAnchor == 9)
        #expect(item.lastReadAt == 77)
        #expect(item.isFavorite)
        #expect(item.title == nil)
        #expect(item.parseStatus == .pending)

        _ = try await apply(h, .delete(.init(opId: "5", itemId: "a", at: 1)))
        #expect(try await h.item("a") == nil)
    }

    @Test func `Tag ops add once by key, remove by key and respect the cap`() async throws {
        let h = try Harness()
        try await h.insert("a", tags: ["ML"])
        _ = try await apply(h, .tag(.init(opId: "1", itemId: "a", at: 1, tag: "ml", present: true)))
        #expect(try await h.tagNames("a") == ["ML"])
        _ = try await apply(h, .tag(.init(opId: "2", itemId: "a", at: 1, tag: "x", present: true)))
        _ = try await apply(h, .tag(.init(opId: "3", itemId: "a", at: 1, tag: "ml", present: false)))
        #expect(try await h.tagNames("a") == ["x"])

        let full = (0..<Limits.maxTagsPerItem).map { "t\($0)" }
        let b = Harness.entity("b")
        try await h.db.write { db in try ItemDao.upsert(db, b, tags: full) }
        _ = try await apply(h, .tag(.init(opId: "4", itemId: "b", at: 1, tag: "extra", present: true)))
        #expect(try await h.tagNames("b").count == Limits.maxTagsPerItem)
        #expect(try await !h.tagNames("b").contains("extra"))
    }

    @Test func `Tag rename and delete apply across items`() async throws {
        let h = try Harness()
        try await h.insert("a", tags: ["ml"])
        let b = Harness.entity("b")
        try await h.db.write { db in try ItemDao.upsert(db, b, tags: ["ML", "x"]) }

        #expect(try await apply(h, .tagRename(.init(opId: "1", at: 1, from: "Ml", to: "AI"))))
        #expect(try await h.tagNames("a") == ["AI"])
        #expect(try await h.tagNames("b") == ["AI", "x"])
        #expect(try await apply(h, .tagDelete(.init(opId: "2", at: 1, tag: "ai"))))
        #expect(try await h.tagNames("b") == ["x"])
    }

    @Test func `Union of tags skips blanks and duplicates by key`() {
        #expect(unionTags(["a"], ["A", " ", "b", "b"]) == ["a", "b"])
        let full = (0..<Limits.maxTagsPerItem).map { "t\($0)" }
        #expect(unionTags(full, ["z"]) == full)
    }

    @Test func `Normalised tags are trimmed, valid, unique by key and capped`() {
        let long = String(repeating: "x", count: Limits.maxTagLength + 1)
        #expect(normalizeTags([" a ", "A", "", long, "b"]) == ["a", "b"])
        let many = (0..<(Limits.maxTagsPerItem + 5)).map { "t\($0)" }
        #expect(normalizeTags(many).count == Limits.maxTagsPerItem)
    }
}

/// Port of Android `OpWriter` behaviour.
struct OpWriterTests {
    struct Boom: Error {}

    @Test func `A failing build writes nothing`() async throws {
        let h = try Harness()
        try await h.insert("a")
        await #expect(throws: Boom.self) {
            try await h.writer.write { _, context -> [WireOp] in
                _ = context
                throw Boom()
            }
        }
        #expect(try await h.pendingCount() == 0)
    }

    @Test func `Ops of one write share one transaction and one time`() async throws {
        let h = try Harness()
        try await h.insert("a")
        try await h.insert("b")
        let queued = try await h.writer.write { _, context in
            [
                .setFavorite(.init(opId: context.newId(), itemId: "a", at: context.at, value: true)),
                .setFavorite(.init(opId: context.newId(), itemId: "b", at: context.at, value: true)),
                .setFavorite(.init(opId: context.newId(), itemId: "missing", at: context.at, value: true)),
            ]
        }
        #expect(queued)
        let ops = try await h.queuedOps()
        #expect(ops.map(\.itemId) == ["a", "b"])
        #expect(Set(ops.map(\.at)).count == 1)
        #expect(Set(ops.map(\.opId)).count == 2)
        #expect(try await h.queued().allSatisfy { $0.createdAt == h.now })
    }

    @Test func `Op times strictly increase across writes`() async throws {
        let h = try Harness()
        try await h.insert("a")
        for value in [true, false, true] {
            try await h.writer.write { _, context in
                [.setFavorite(.init(opId: context.newId(), itemId: "a", at: context.at, value: value))]
            }
            try await h.writer.write { _, context in
                [.setProgress(.init(opId: context.newId(), itemId: "a", at: context.at, progress: 0.5))]
            }
        }
        let ats = try await h.queuedOps().map(\.at)
        #expect(ats == ats.sorted())
        #expect(Set(ats).count == ats.count)
    }

    @Test func `A write with no applicable ops queues nothing`() async throws {
        let h = try Harness()
        #expect(try await !h.writer.write { _, _ in [] })
        #expect(try await h.pendingCount() == 0)
    }
}
