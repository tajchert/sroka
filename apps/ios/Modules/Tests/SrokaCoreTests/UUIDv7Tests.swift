import Foundation
import Testing

@testable import SrokaCore

struct UUIDv7Tests {
    @Test func `Generates a valid lower-case v7 uuid`() {
        let id = UUIDv7.Generator().next(nowMilliseconds: 1_760_400_723_120)
        #expect(UUIDv7.isUuid(id))
        #expect(id == id.lowercased())
        #expect(Array(id.utf8)[14] == UInt8(ascii: "7"))
        #expect("89ab".contains(Array(id)[19]))
        #expect(id.count == 36)
    }

    @Test func `Encodes the timestamp`() {
        let t: Int64 = 2_000_000_000_000
        #expect(UUIDv7.time(of: UUIDv7.Generator().next(nowMilliseconds: t)) == t)
    }

    @Test func `Is strictly increasing within the same millisecond`() {
        let generator = UUIDv7.Generator()
        let ids = (0..<10_000).map { _ in generator.next(nowMilliseconds: 1_900_000_000_000) }
        for index in 1..<ids.count { #expect(ids[index] > ids[index - 1]) }
        #expect(Set(ids).count == ids.count)
    }

    @Test func `Stays monotonic when the clock goes backwards`() {
        let generator = UUIDv7.Generator()
        let a = generator.next(nowMilliseconds: 1_950_000_000_000)
        let b = generator.next(nowMilliseconds: 1_940_000_000_000)
        #expect(b > a)
    }

    @Test func `Advances the timestamp when the counter overflows`() {
        let generator = UUIDv7.Generator()
        var ids: [String] = []
        for _ in 0..<5_000 { ids.append(generator.next(nowMilliseconds: 1_800_000_000_000)) }
        #expect(ids.last.flatMap(UUIDv7.time(of:))! > 1_800_000_000_000)
        for index in 1..<ids.count { #expect(ids[index] > ids[index - 1]) }
    }

    @Test func `Shared generator produces ordered ids`() {
        let a = UUIDv7.next(nowMilliseconds: 2_100_000_000_000)
        let b = UUIDv7.next(nowMilliseconds: 2_100_000_000_000)
        #expect(b > a)
    }

    @Test func `isUuid rejects junk`() {
        #expect(!UUIDv7.isUuid("nope"))
        #expect(!UUIDv7.isUuid("0192f3c4-1111-9222-8333-444455556666"))
        #expect(UUIDv7.isUuid("0192F3C4-1111-7222-8333-444455556666"))
        #expect(UUIDv7.time(of: "0192f3c4-1111-4222-8333-444455556666") == nil)
    }
}
