import Foundation
import Testing

@testable import SrokaCore

/// Mirrors `packages/shared/src/ops.test.ts` ("accepts every op type") and Android's `WireOp` payloads.
struct WireOpTests {
    private let itemId = "0192f3c4-1111-7222-8333-444455556666"
    private let at: Int64 = 1_760_400_723_120

    private var everyOp: [WireOp] {
        [
            .add(
                .init(
                    opId: "a1", itemId: itemId, at: at, url: "https://example.com/post?utm_source=x",
                    title: "Optional", tags: ["travel"], source: .share, savedAt: at, onDuplicate: .readd)),
            .setStatus(.init(opId: "a2", itemId: itemId, at: at, status: .archived)),
            .setFavorite(.init(opId: "a3", itemId: itemId, at: at, value: true)),
            .setProgress(.init(opId: "a4", itemId: itemId, at: at, progress: 0.42, anchor: 17)),
            .tag(.init(opId: "a5", itemId: itemId, at: at, tag: "to-cook", present: true)),
            .tagRename(.init(opId: "a6", at: at, from: "ml", to: "machine-learning")),
            .delete(.init(opId: "a7", itemId: itemId, at: at)),
            .refresh(.init(opId: "a8", itemId: itemId, at: at)),
            .setTitle(.init(opId: "a9", itemId: itemId, at: at, title: "New")),
            .tagDelete(.init(opId: "a10", at: at, tag: "old")),
        ]
    }

    @Test func `All ten op types round-trip through the canonical payload`() throws {
        #expect(everyOp.count == WireOp.Kind.allCases.count)
        for op in everyOp {
            let parsed = try #require(WireOp.parse(payload: op.payload), "\(op.kind)")
            #expect(parsed == op)
            #expect(parsed.payload == op.payload)
        }
    }

    @Test func `Payloads are canonical compact JSON with sorted keys`() {
        let status = WireOp.setStatus(.init(opId: "a2", itemId: itemId, at: at, status: .archived))
        #expect(
            status.payload
                == #"{"at":1760400723120,"itemId":"0192f3c4-1111-7222-8333-444455556666","opId":"a2","status":"archived","type":"item.setStatus"}"#
        )
        let rename = WireOp.tagRename(.init(opId: "a6", at: at, from: "ml", to: "machine-learning"))
        #expect(
            rename.payload
                == #"{"at":1760400723120,"from":"ml","opId":"a6","to":"machine-learning","type":"tag.rename"}"#)
        let progress = WireOp.setProgress(.init(opId: "a4", itemId: itemId, at: at, progress: 0.42, anchor: 17))
        #expect(progress.payload.contains(#""anchor":17"#) && progress.payload.contains(#""progress":0.42"#))
    }

    @Test func `Nil fields are omitted not sent as null`() {
        let add = WireOp.add(.init(opId: "x", itemId: itemId, at: at, url: "https://a.b/"))
        #expect(!add.payload.contains("null"))
        #expect(!add.payload.contains("title") && !add.payload.contains("source") && !add.payload.contains("savedAt"))
        let progress = WireOp.setProgress(.init(opId: "x", itemId: itemId, at: at, progress: 1))
        #expect(!progress.payload.contains("anchor"))
    }

    @Test func `Progress is clamped when encoding even after a later mutation`() {
        var op = WireOp.SetProgress(opId: "x", itemId: itemId, at: at, progress: 0.5)
        op.progress = .nan
        #expect(WireOp.setProgress(op).payload.contains(#""progress":0"#))
        op.progress = 7
        #expect(WireOp.setProgress(op).payload.contains(#""progress":1"#))
    }

    @Test func `Titles are trimmed like JavaScript, so U+0085 stays and U+FEFF goes`() {
        func sent(_ title: String) -> String? {
            guard
                case .setTitle(let op)? = WireOp.parse(
                    payload: WireOp.setTitle(.init(opId: "y", itemId: itemId, at: at, title: title)).payload)
            else { return nil }
            return op.title
        }
        #expect(sent("\u{FEFF} Hi \u{3000}") == "Hi")
        #expect(sent("\u{85}Hi") == "\u{85}Hi")
    }

    @Test func `Slashes and non-ASCII are not escaped`() {
        let add = WireOp.add(.init(opId: "x", itemId: itemId, at: at, url: "https://a.b/ü/c", tags: ["żółw"]))
        #expect(add.payload.contains(#""url":"https://a.b/ü/c""#))
        #expect(add.payload.contains(#""tags":["żółw"]"#))
    }

    @Test func `Encoding the same op always gives the same bytes`() {
        let op = everyOp[0]
        let payloads = Set((0..<20).map { _ in op.payload })
        #expect(payloads.count == 1)
    }

    @Test func `Title is clamped and a cleared title is sent as an empty string`() throws {
        let long = String(repeating: "a", count: 1_500)
        let add = WireOp.add(.init(opId: "x", itemId: itemId, at: at, url: "https://a.b/", title: "  " + long))
        let parsed = try #require(WireOp.parse(payload: add.payload))
        guard case .add(let op) = parsed else {
            Issue.record("not an add")
            return
        }
        #expect(op.title?.utf16.count == Limits.maxTitleLength)
        let cleared = WireOp.setTitle(.init(opId: "y", itemId: itemId, at: at, title: nil))
        #expect(cleared.payload.contains(#""title":"""#))
        guard case .setTitle(let back)? = WireOp.parse(payload: cleared.payload) else {
            Issue.record("not a title")
            return
        }
        #expect(back.title == nil)
    }

    @Test func `Progress is clamped to the range the server accepts`() {
        #expect(WireOp.SetProgress(opId: "x", itemId: itemId, at: at, progress: 1.7).progress == 1)
        #expect(WireOp.SetProgress(opId: "x", itemId: itemId, at: at, progress: -2).progress == 0)
        #expect(WireOp.SetProgress(opId: "x", itemId: itemId, at: at, progress: .nan).progress == 0)
    }

    @Test func `Unknown source is not sent`() {
        let add = WireOp.add(.init(opId: "x", itemId: itemId, at: at, url: "https://a.b/", source: .unknown))
        #expect(!add.payload.contains("source"))
        let ext = WireOp.add(.init(opId: "x", itemId: itemId, at: at, url: "https://a.b/", source: .extensionSource))
        #expect(ext.payload.contains(#""source":"extension""#))
    }

    @Test func `Parsing ignores unknown keys and rejects unknown or incomplete ops`() throws {
        let extra = #"{"opId":"a","type":"item.delete","itemId":"i1","at":5,"futureField":{"x":1}}"#
        #expect(WireOp.parse(payload: extra) == .delete(.init(opId: "a", itemId: "i1", at: 5)))
        #expect(WireOp.parse(payload: #"{"opId":"a","type":"item.nope","itemId":"i1","at":5}"#) == nil)
        #expect(WireOp.parse(payload: #"{"opId":"a","type":"item.setStatus","itemId":"i1","at":5}"#) == nil)
        #expect(
            WireOp.parse(payload: #"{"opId":"a","type":"item.setStatus","itemId":"i1","at":5,"status":"deleted"}"#)
                == nil)
        #expect(WireOp.parse(payload: "not json") == nil)
    }

    @Test func `Rewriting an item id decodes and re-encodes instead of replacing text`() throws {
        // The url contains the old id as text; only the itemId field may change.
        let old = "item-1"
        let add = WireOp.add(.init(opId: "op-1", itemId: old, at: at, url: "https://a.b/\(old)", tags: [old]))
        let rewritten = try #require(WireOp.rewrite(payload: add.payload, itemId: "server-9"))
        guard case .add(let op)? = WireOp.parse(payload: rewritten) else {
            Issue.record("not an add")
            return
        }
        #expect(op.itemId == "server-9")
        #expect(op.url == "https://a.b/\(old)")
        #expect(op.tags == [old])
        #expect(op.opId == "op-1")
        #expect(rewritten == add.rewriting(itemId: "server-9").payload)
    }

    @Test func `Rewriting an op id keeps everything else`() throws {
        let op = WireOp.setFavorite(.init(opId: "old", itemId: itemId, at: at, value: false))
        let rewritten = try #require(WireOp.rewrite(payload: op.payload, opId: "new"))
        #expect(
            WireOp.parse(payload: rewritten) == .setFavorite(.init(opId: "new", itemId: itemId, at: at, value: false)))
    }

    @Test func `Rewriting tag-level ops only changes the op id`() throws {
        let op = WireOp.tagDelete(.init(opId: "t", at: at, tag: "x"))
        #expect(op.itemId == nil)
        #expect(op.rewriting(itemId: "ignored") == op)
        #expect(WireOp.rewrite(payload: "garbage", itemId: "x") == nil)
    }
}
