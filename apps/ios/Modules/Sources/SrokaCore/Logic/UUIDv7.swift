import Foundation
import Synchronization

/// UUIDv7 (RFC 9562), port of shared `uuidv7`: 48-bit unix ms, version 7, 12-bit counter, variant, random tail.
/// Monotonic per generator: within one millisecond the 12-bit `rand_a` field counts up (on overflow the timestamp
/// advances by 1 ms) and a clock that goes backwards keeps the last timestamp, so ids sort lexicographically in
/// creation order. Always lower-case.
public enum UUIDv7 {
    /// The process-wide generator behind `UUIDv7.next(nowMilliseconds:)`.
    public static let shared = Generator()

    /// Next id from the shared generator.
    public static func next(nowMilliseconds: Int64) -> String { shared.next(nowMilliseconds: nowMilliseconds) }

    /// Next id from the shared generator, stamped with `date`.
    public static func next(at date: Date) -> String {
        shared.next(nowMilliseconds: Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))
    }

    /// Unix-ms timestamp encoded in a UUIDv7, or nil if `id` is not a v7 UUID.
    public static func time(of id: String) -> Int64? {
        guard isUuid(id), Array(id.utf8)[14] == 0x37 else { return nil }
        return Int64(id.replacingOccurrences(of: "-", with: "").prefix(12), radix: 16)
    }

    /// Any RFC 9562 UUID (versions 1-8), either case.
    public static func isUuid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                if byte != 0x2D { return false }
            case 14:
                if !(0x31...0x38).contains(byte) { return false }
            case 19:
                if !"89abAB".utf8.contains(byte) { return false }
            default:
                let isHex = (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte) || (0x41...0x46).contains(byte)
                if !isHex { return false }
            }
        }
        return true
    }

    /// Monotonic generator. Create one per test for isolation; production code uses `UUIDv7.shared`.
    public final class Generator: Sendable {
        private struct State {
            var lastMs: Int64 = -1
            var counter = 0
        }

        private let state = Mutex(State())

        public init() {}

        public func next(nowMilliseconds: Int64) -> String {
            var generator = SystemRandomNumberGenerator()
            return next(nowMilliseconds: nowMilliseconds, using: &generator)
        }

        func next(nowMilliseconds: Int64, using random: inout some RandomNumberGenerator) -> String {
            let (ms, counter) = state.withLock { state -> (Int64, Int) in
                var ms = nowMilliseconds
                if ms <= state.lastMs {
                    ms = state.lastMs
                    state.counter += 1
                    if state.counter > 0xFFF {
                        ms = state.lastMs + 1
                        state.counter = Int.random(in: 0..<0x800, using: &random)
                    }
                } else {
                    state.counter = Int.random(in: 0..<0x800, using: &random)
                }
                state.lastMs = ms
                return (ms, state.counter)
            }

            var bytes = [UInt8](repeating: 0, count: 16)
            for index in 0..<16 { bytes[index] = UInt8.random(in: 0...255, using: &random) }
            for index in 0..<6 { bytes[index] = UInt8(truncatingIfNeeded: ms >> Int64(8 * (5 - index))) }
            bytes[6] = 0x70 | UInt8((counter >> 8) & 0x0F)
            bytes[7] = UInt8(counter & 0xFF)
            bytes[8] = 0x80 | (bytes[8] & 0x3F)

            let hex = Array("0123456789abcdef".utf8)
            var out: [UInt8] = []
            out.reserveCapacity(36)
            for (index, byte) in bytes.enumerated() {
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
                if index == 3 || index == 5 || index == 7 || index == 9 { out.append(0x2D) }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}
