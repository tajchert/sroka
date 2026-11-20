import CryptoKit
import Foundation

/// Port of shared `normalizeUrl` / `urlHash` / `displayDomain` / `extractFirstUrl` / `isHttpUrl`
/// (`packages/shared/src/url.ts`, api.md §13). The server recomputes `canonicalUrl` and `url_hash`, so the output must
/// match its WHATWG URL parser byte for byte. This is a hand-written parser for the WHATWG subset the rules need;
/// Foundation's `URL` / `URLComponents` are never used (they differ on percent-encoding, IDN and query
/// re-serialisation).
///
/// 1. Only http/https; input trimmed. 2. Scheme and host lower-cased, IDN to punycode, IPv4/IPv6 hosts in canonical
/// form, trailing host dot removed. 3. Default ports dropped. 4. Userinfo and fragment removed. 5. Tracking params
/// removed. 6. Remaining params stably sorted by name and re-serialised form-urlencoded (space becomes `+`).
/// 7. Path kept (trailing slash kept; empty becomes `/`; dot segments resolved). 8. `www.` kept, scheme not upgraded.
public enum UrlNormalizer {
    /// Exact-name tracking parameters (compared lower-case); any `utm_*` is also tracking.
    public static let trackingParams: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_eid", "mc_cid",
        "igshid", "ref_src", "_hsenc", "_hsmktg", "yclid",
    ]

    public static func isTrackingParam(_ name: String) -> Bool {
        let lowered = jsLowercased(name)
        return lowered.hasPrefix("utm_") || trackingParams.contains(lowered)
    }

    /// Canonical form of `input`, or nil if it is not an absolute http(s) URL with a host.
    public static func normalize(_ input: String) -> String? {
        guard var parsed = parse(jsTrim(input)) else { return nil }
        // The TypeScript strips trailing dots after parsing; an all-dots host would leave nothing and the
        // hostname setter ignores an empty value, so such a host is kept as parsed.
        if parsed.host.hasSuffix(".") {
            let stripped = String(parsed.host.reversed().drop(while: { $0 == "." }).reversed())
            if !stripped.isEmpty { parsed.host = stripped }
        }
        var kept: [(index: Int, name: String, value: String)] = []
        for (index, pair) in parseQuery(parsed.query ?? "").enumerated() where !isTrackingParam(pair.name) {
            kept.append((index, pair.name, pair.value))
        }
        kept.sort { lhs, rhs in
            let order = compareUtf16(lhs.name, rhs.name)
            return order == 0 ? lhs.index < rhs.index : order < 0
        }
        var query = ""
        if !kept.isEmpty {
            query = "?" + kept.map { formEncode($0.name) + "=" + formEncode($0.value) }.joined(separator: "&")
        }
        let port = parsed.port.map { ":\($0)" } ?? ""
        return "\(parsed.scheme)://\(parsed.host)\(port)\(parsed.path)\(query)"
    }

    /// `sha256(canonicalUrl)` as lower-case hex. Pass the output of `normalize`.
    public static func urlHash(_ canonicalUrl: String) -> String {
        SHA256.hash(data: Data(canonicalUrl.utf8)).map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    /// True if `s` parses as an absolute http(s) URL with a host (like `new URL(s)`: only C0 controls and spaces
    /// are stripped around it, not other whitespace).
    public static func isHttpUrl(_ s: String) -> Bool { parse(s) != nil }

    /// Lower-cased (punycode) host of `url`, or nil if it is not an http(s) URL.
    public static func hostOf(_ url: String) -> String? { parse(url)?.host }

    /// Host without a leading `www.`; empty if `url` has no parsable host.
    public static func displayDomain(_ url: String) -> String {
        guard let host = hostOf(url) else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// First http(s) URL in free text (share text "Title https://…"), without trailing punctuation or unbalanced
    /// closing brackets. Port of shared `extractFirstUrl`; the URL ends at JavaScript `\s` (Unicode separators
    /// but not U+0085, as in the TypeScript).
    public static func extractFirstUrl(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard var url = firstUrlRun(in: scalars) else { return nil }
        let brackets: [(open: Unicode.Scalar, close: Unicode.Scalar)] = [("(", ")"), ("[", "]"), ("{", "}")]
        while true {
            let before = url
            while let last = url.last, trailingPunctuation.contains(last) { url.removeLast() }
            for (open, close) in brackets where url.last == close {
                if url.filter({ $0 == close }).count > url.filter({ $0 == open }).count { url.removeLast() }
            }
            if url == before { break }
        }
        let result = String(String.UnicodeScalarView(url))
        return isHttpUrl(result) ? result : nil
    }

    // MARK: - Parsing

    private struct Parsed {
        var scheme: String
        var host: String
        var port: Int?
        var path: String
        var query: String?
    }

    /// Parses like `new URL(input)` restricted to http(s) (no base URL).
    private static func parse(_ input: String) -> Parsed? {
        // The URL parser strips leading/trailing C0 controls and spaces, and removes tab/LF/CR everywhere.
        var bytes = Array(input.utf8).filter { $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
        while let first = bytes.first, first <= 0x20 { bytes.removeFirst() }
        while let last = bytes.last, last <= 0x20 { bytes.removeLast() }

        var index = 0
        guard index < bytes.count, isAsciiAlpha(bytes[index]) else { return nil }
        while index < bytes.count,
            isAsciiAlpha(bytes[index]) || isDigit(bytes[index]) || "+-.".utf8.contains(bytes[index])
        {
            index += 1
        }
        guard index < bytes.count, bytes[index] == 0x3A else { return nil }
        let scheme = String(decoding: bytes[0..<index].map(lowerAscii), as: UTF8.self)
        guard scheme == "http" || scheme == "https" else { return nil }

        var rest = Array(bytes[(index + 1)...])
        while let first = rest.first, first == 0x2F || first == 0x5C { rest.removeFirst() }

        let authorityEnd =
            rest.firstIndex(where: { $0 == 0x2F || $0 == 0x5C || $0 == 0x3F || $0 == 0x23 }) ?? rest.count
        let authority = Array(rest[0..<authorityEnd])
        let hostPort = authority.lastIndex(of: 0x40).map { Array(authority[($0 + 1)...]) } ?? authority

        var rawHost: [UInt8]
        var rawPort: [UInt8]
        if hostPort.first == 0x5B {
            guard let close = hostPort.firstIndex(of: 0x5D) else { return nil }
            rawHost = Array(hostPort[0...close])
            let after = Array(hostPort[(close + 1)...])
            if !after.isEmpty && after.first != 0x3A { return nil }
            rawPort = Array(after.dropFirst())
        } else if let colon = hostPort.firstIndex(of: 0x3A) {
            rawHost = Array(hostPort[0..<colon])
            rawPort = Array(hostPort[(colon + 1)...])
        } else {
            rawHost = hostPort
            rawPort = []
        }

        guard let host = parseHost(rawHost) else { return nil }
        var port: Int?
        if !rawPort.isEmpty {
            guard rawPort.allSatisfy(isDigit), rawPort.count <= 8,
                let value = Int(String(decoding: rawPort, as: UTF8.self)),
                value <= 65535
            else { return nil }
            if !((scheme == "http" && value == 80) || (scheme == "https" && value == 443)) { port = value }
        }

        // Path ends at the first `?` or `#`; the query runs to the first `#`.
        let tail = Array(rest[authorityEnd...])
        let pathEnd = tail.firstIndex(where: { $0 == 0x3F || $0 == 0x23 }) ?? tail.count
        let rawPath = Array(tail[0..<pathEnd])
        var query: String?
        if pathEnd < tail.count, tail[pathEnd] == 0x3F {
            let queryBytes = tail[(pathEnd + 1)...]
            let queryEnd = queryBytes.firstIndex(of: 0x23) ?? queryBytes.endIndex
            query = String(decoding: queryBytes[queryBytes.startIndex..<queryEnd], as: UTF8.self)
        }
        return Parsed(scheme: scheme, host: host, port: port, path: normalizePath(rawPath), query: query)
    }

    // MARK: Host

    private static func parseHost(_ raw: [UInt8]) -> String? {
        if raw.isEmpty { return nil }
        if raw.first == 0x5B {
            guard raw.last == 0x5D, let pieces = parseIPv6(Array(raw.dropFirst().dropLast())) else { return nil }
            return "[" + serializeIPv6(pieces) + "]"
        }
        let decoded = String(decoding: percentDecode(raw), as: UTF8.self)
        guard let ascii = domainToAscii(decoded), !ascii.isEmpty else { return nil }
        if ascii.unicodeScalars.contains(where: isForbiddenDomainScalar) { return nil }
        if endsInNumber(ascii) {
            guard let address = parseIPv4(ascii) else { return nil }
            return (0..<4).map { String((address >> UInt32(8 * (3 - $0))) & 0xFF) }.joined(separator: ".")
        }
        return ascii
    }

    private static func isForbiddenDomainScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value <= 0x20 || value == 0x7F { return true }
        return " #%/:<>?@[\\]^|".unicodeScalars.contains(scalar)
    }

    /// UTS 46 (non-transitional) as far as hosts need it: map, NFKC, punycode per label.
    private static func domainToAscii(_ domain: String) -> String? {
        var labels: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            labels.append(String(current))
            current = String.UnicodeScalarView()
        }
        for scalar in domain.unicodeScalars {
            switch scalar.value {
            case 0x2E, 0x3002, 0xFF0E, 0xFF61: flush()
            default: current.append(scalar)
            }
        }
        flush()
        var out: [String] = []
        for label in labels {
            if label.unicodeScalars.allSatisfy({ $0.isASCII }) {
                out.append(
                    String(
                        String.UnicodeScalarView(
                            label.unicodeScalars.map { Unicode.Scalar(lowerAscii(UInt8($0.value))) })))
                continue
            }
            var mapped = String.UnicodeScalarView()
            for scalar in label.unicodeScalars where !isIdnaIgnored(scalar) { mapped.append(scalar) }
            let folded = String(mapped).lowercased().precomposedStringWithCompatibilityMapping
            let normalized = folded.precomposedStringWithCanonicalMapping
            if normalized.unicodeScalars.allSatisfy({ $0.isASCII }) {
                out.append(normalized)
            } else {
                guard let encoded = punycodeEncode(Array(normalized.unicodeScalars.map(\.value))) else { return nil }
                out.append("xn--" + encoded)
            }
        }
        return out.joined(separator: ".")
    }

    private static func isIdnaIgnored(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x200B, 0x2060, 0xFEFF, 0x034F, 0x180B...0x180D, 0xFE00...0xFE0F: true
        default: false
        }
    }

    /// RFC 3492 encoder.
    private static func punycodeEncode(_ input: [UInt32]) -> String? {
        let base: UInt32 = 36
        let tMin: UInt32 = 1
        let tMax: UInt32 = 26
        let skew: UInt32 = 38
        let damp: UInt32 = 700
        var n: UInt32 = 128
        var delta: UInt32 = 0
        var bias: UInt32 = 72
        var output = input.filter { $0 < 128 }.map { Character(Unicode.Scalar($0)!) }
        let basicCount = UInt32(output.count)
        var handled = basicCount
        if basicCount > 0 { output.append("-") }

        func digit(_ d: UInt32) -> Character {
            Character(Unicode.Scalar(d < 26 ? d + 97 : d - 26 + 48)!)
        }
        func adapt(_ deltaIn: UInt32, _ points: UInt32, _ first: Bool) -> UInt32 {
            var d = first ? deltaIn / damp : deltaIn / 2
            d += d / points
            var k: UInt32 = 0
            while d > ((base - tMin) * tMax) / 2 {
                d /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * d / (d + skew)
        }

        while handled < UInt32(input.count) {
            guard let m = input.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            let (sum, overflow2) = delta.addingReportingOverflow(product)
            if overflow || overflow2 { return nil }
            delta = sum
            n = m
            for c in input {
                if c < n {
                    delta += 1
                } else if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    // MARK: IPv4

    private static func endsInNumber(_ host: String) -> Bool {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true {
            if parts.count == 1 { return false }
            parts.removeLast()
        }
        guard let last = parts.last, !last.isEmpty else { return false }
        if last.utf8.allSatisfy(isDigit) { return true }
        return parseIPv4Number(String(last)) != nil
    }

    private static func parseIPv4Number(_ text: String) -> UInt64? {
        var input = Substring(text)
        if input.isEmpty { return nil }
        var radix = 10
        if input.hasPrefix("0x") || input.hasPrefix("0X") {
            input = input.dropFirst(2)
            radix = 16
        } else if input.count >= 2, input.hasPrefix("0") {
            input = input.dropFirst()
            radix = 8
        }
        if input.isEmpty { return 0 }
        var value: UInt64 = 0
        for byte in input.utf8 {
            guard let digit = hexValue(byte), digit < radix else { return nil }
            let (product, o1) = value.multipliedReportingOverflow(by: UInt64(radix))
            let (sum, o2) = product.addingReportingOverflow(UInt64(digit))
            if o1 || o2 { return UInt64.max }  // beyond any valid range; callers reject it as too large
            value = sum
        }
        return value
    }

    private static func parseIPv4(_ host: String) -> UInt32? {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.last?.isEmpty == true, parts.count > 1 { parts.removeLast() }
        if parts.count > 4 { return nil }
        var numbers: [UInt64] = []
        for part in parts {
            guard let number = parseIPv4Number(part) else { return nil }
            numbers.append(number)
        }
        if numbers.dropLast().contains(where: { $0 > 255 }) { return nil }
        let last = numbers[numbers.count - 1]
        var limit: UInt64 = 1
        for _ in 0..<(5 - numbers.count) { limit *= 256 }
        if last >= limit { return nil }
        var address = last
        for (index, number) in numbers.dropLast().enumerated() {
            var weight: UInt64 = 1
            for _ in 0..<(3 - index) { weight *= 256 }
            address += number * weight
        }
        return UInt32(address)
    }

    // MARK: IPv6

    private static func parseIPv6(_ input: [UInt8]) -> [UInt16]? {
        var address = [UInt16](repeating: 0, count: 8)
        var pieceIndex = 0
        var compress: Int?
        var pointer = 0
        func at(_ offset: Int) -> UInt8? { offset < input.count ? input[offset] : nil }

        if at(0) == 0x3A {
            guard at(1) == 0x3A else { return nil }
            pointer += 2
            pieceIndex += 1
            compress = pieceIndex
        }
        while pointer < input.count {
            if pieceIndex == 8 { return nil }
            if input[pointer] == 0x3A {
                if compress != nil { return nil }
                pointer += 1
                pieceIndex += 1
                compress = pieceIndex
                continue
            }
            var value: UInt32 = 0
            var length = 0
            while length < 4, let byte = at(pointer), let digit = hexValue(byte) {
                value = value * 16 + UInt32(digit)
                pointer += 1
                length += 1
            }
            if at(pointer) == 0x2E {
                if length == 0 { return nil }
                pointer -= length
                if pieceIndex > 6 { return nil }
                var numbersSeen = 0
                while pointer < input.count {
                    var ipv4Piece: Int?
                    if numbersSeen > 0 {
                        if at(pointer) == 0x2E, numbersSeen < 4 { pointer += 1 } else { return nil }
                    }
                    guard let first = at(pointer), isDigit(first) else { return nil }
                    while let byte = at(pointer), isDigit(byte) {
                        let number = Int(byte - 0x30)
                        if let piece = ipv4Piece {
                            if piece == 0 { return nil }
                            ipv4Piece = piece * 10 + number
                        } else {
                            ipv4Piece = number
                        }
                        if ipv4Piece! > 255 { return nil }
                        pointer += 1
                    }
                    address[pieceIndex] = address[pieceIndex] * 0x100 + UInt16(ipv4Piece!)
                    numbersSeen += 1
                    if numbersSeen == 2 || numbersSeen == 4 { pieceIndex += 1 }
                }
                if numbersSeen != 4 { return nil }
                break
            } else if at(pointer) == 0x3A {
                pointer += 1
                if pointer >= input.count { return nil }
            } else if pointer < input.count {
                return nil
            }
            address[pieceIndex] = UInt16(value)
            pieceIndex += 1
        }
        if let compress {
            var swaps = pieceIndex - compress
            pieceIndex = 7
            while pieceIndex != 0 && swaps > 0 {
                address.swapAt(pieceIndex, compress + swaps - 1)
                pieceIndex -= 1
                swaps -= 1
            }
        } else if pieceIndex != 8 {
            return nil
        }
        return address
    }

    private static func serializeIPv6(_ address: [UInt16]) -> String {
        var bestStart = -1
        var bestLength = 0
        var runStart = -1
        var runLength = 0
        for index in 0..<8 {
            if address[index] == 0 {
                if runStart < 0 { runStart = index }
                runLength += 1
                if runLength > bestLength {
                    bestLength = runLength
                    bestStart = runStart
                }
            } else {
                runStart = -1
                runLength = 0
            }
        }
        let compress = bestLength > 1 ? bestStart : -1
        var output = ""
        var ignoreZeros = false
        for index in 0..<8 {
            if ignoreZeros && address[index] == 0 { continue }
            if ignoreZeros { ignoreZeros = false }
            if compress == index {
                output += index == 0 ? "::" : ":"
                ignoreZeros = true
                continue
            }
            output += String(address[index], radix: 16)
            if index != 7 { output += ":" }
        }
        return output
    }

    // MARK: Path and query

    private static func normalizePath(_ raw: [UInt8]) -> String {
        if raw.isEmpty { return "/" }
        let unified = raw.map { $0 == 0x5C ? UInt8(0x2F) : $0 }
        let segments = unified.dropFirst().split(separator: 0x2F, omittingEmptySubsequences: false).map(Array.init)
        var out: [[UInt8]] = []
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            let lowered = String(decoding: segment.map(lowerAscii), as: UTF8.self)
            switch lowered {
            case ".", "%2e":
                if isLast { out.append([]) }
            case "..", ".%2e", "%2e.", "%2e%2e":
                if !out.isEmpty { out.removeLast() }
                if isLast { out.append([]) }
            default:
                out.append(segment)
            }
        }
        var result = [UInt8(0x2F)]
        for (index, segment) in out.enumerated() {
            if index > 0 { result.append(0x2F) }
            for byte in segment {
                if byte < 0x20 || byte > 0x7E || pathEncodeSet.contains(byte) {
                    result.append(contentsOf: [0x25, hexUpper[Int(byte >> 4)], hexUpper[Int(byte & 0x0F)]])
                } else {
                    result.append(byte)
                }
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Path percent-encode set beyond C0 controls and non-ASCII: space " # < > ? ^ ` { }.
    private static let pathEncodeSet: Set<UInt8> = Set(" \"#<>?^`{}".utf8)
    private static let hexUpper = Array("0123456789ABCDEF".utf8)

    private static func parseQuery(_ query: String) -> [(name: String, value: String)] {
        Array(query.utf8).split(separator: 0x26, omittingEmptySubsequences: true).map { part in
            let bytes = Array(part)
            let equals = bytes.firstIndex(of: 0x3D)
            let name = equals.map { Array(bytes[0..<$0]) } ?? bytes
            let value = equals.map { Array(bytes[($0 + 1)...]) } ?? []
            return (decodeQueryComponent(name), decodeQueryComponent(value))
        }
    }

    private static func decodeQueryComponent(_ bytes: [UInt8]) -> String {
        String(decoding: percentDecode(bytes.map { $0 == 0x2B ? 0x20 : $0 }), as: UTF8.self)
    }

    private static func percentDecode(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(0x25) else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25, index + 2 < bytes.count, let high = hexValue(bytes[index + 1]),
                let low = hexValue(bytes[index + 2])
            {
                out.append(UInt8(high * 16 + low))
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return out
    }

    /// `application/x-www-form-urlencoded` byte serializer (as `URLSearchParams.toString()`).
    private static func formEncode(_ text: String) -> String {
        var out: [UInt8] = []
        for byte in text.utf8 {
            if isAsciiAlpha(byte) || isDigit(byte) || "*-._".utf8.contains(byte) {
                out.append(byte)
            } else if byte == 0x20 {
                out.append(0x2B)
            } else {
                out.append(contentsOf: [0x25, hexUpper[Int(byte >> 4)], hexUpper[Int(byte & 0x0F)]])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: extractFirstUrl helpers

    private static let trailingPunctuation: Set<Unicode.Scalar> = [
        ".", ",", ";", ":", "!", "?", "'", "\"", "\u{BB}", "\u{201D}", "\u{2019}", "\u{2026}",
    ]

    private static func isUrlDelimiter(_ scalar: Unicode.Scalar) -> Bool {
        if isJsWhitespace(scalar) { return true }
        switch scalar {
        case "<", ">", "\"", "'", "`": return true
        default: return false
        }
    }

    /// Leftmost `https?://` (any case) followed by at least one non-delimiter scalar, up to the next delimiter.
    private static func firstUrlRun(in scalars: [Unicode.Scalar]) -> [Unicode.Scalar]? {
        let lowered = scalars.map { Unicode.Scalar(lowerAscii(UInt8(truncatingIfNeeded: $0.value))) }
        func matches(_ start: Int, _ literal: String) -> Bool {
            let chars = Array(literal.unicodeScalars)
            guard start + chars.count <= scalars.count else { return false }
            for (offset, char) in chars.enumerated()
            where scalars[start + offset].isASCII == false || lowered[start + offset] != char {
                return false
            }
            return true
        }
        var start = 0
        while start < scalars.count {
            for prefix in ["https://", "http://"] where matches(start, prefix) {
                var end = start + prefix.unicodeScalars.count
                let bodyStart = end
                while end < scalars.count, !isUrlDelimiter(scalars[end]) { end += 1 }
                if end > bodyStart { return Array(scalars[start..<end]) }
            }
            start += 1
        }
        return nil
    }
}

// MARK: - Shared helpers (also used by tag normalisation)

/// JavaScript `String.prototype.trim` / `\s` whitespace: WhiteSpace and LineTerminator code points.
func isJsWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
    default: false
    }
}

/// JavaScript `String.prototype.trim`.
func jsTrim(_ text: String) -> String {
    var scalars = Substring(text).unicodeScalars
    while let first = scalars.first, isJsWhitespace(first) { scalars.removeFirst() }
    while let last = scalars.last, isJsWhitespace(last) { scalars.removeLast() }
    return String(scalars)
}

/// Locale-independent lower-casing like `String.prototype.toLowerCase` (full mapping, final-sigma rule).
func jsLowercased(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    guard scalars.contains(where: { $0.value == 0x3A3 }) else { return text.lowercased() }
    var out = String.UnicodeScalarView()
    for (index, scalar) in scalars.enumerated() {
        if scalar.value == 0x3A3 {
            out.append(isFinalSigma(scalars, index) ? "\u{3C2}" : "\u{3C3}")
        } else {
            out.append(contentsOf: String(scalar).lowercased().unicodeScalars)
        }
    }
    return String(out)
}

/// Unicode Final_Sigma: preceded by a cased letter (skipping case-ignorable) and not followed by one.
private func isFinalSigma(_ scalars: [Unicode.Scalar], _ index: Int) -> Bool {
    var before = index - 1
    while before >= 0, scalars[before].properties.isCaseIgnorable { before -= 1 }
    guard before >= 0, scalars[before].properties.isCased else { return false }
    var after = index + 1
    while after < scalars.count, scalars[after].properties.isCaseIgnorable { after += 1 }
    return !(after < scalars.count && scalars[after].properties.isCased)
}

private func isAsciiAlpha(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }

private func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

private func lowerAscii(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte + 32 : byte }

private func hexValue(_ byte: UInt8) -> Int? {
    switch byte {
    case 0x30...0x39: Int(byte - 0x30)
    case 0x41...0x46: Int(byte - 0x41 + 10)
    case 0x61...0x66: Int(byte - 0x61 + 10)
    default: nil
    }
}

private func compareUtf16(_ lhs: String, _ rhs: String) -> Int {
    var left = lhs.utf16.makeIterator()
    var right = rhs.utf16.makeIterator()
    while true {
        switch (left.next(), right.next()) {
        case (nil, nil): return 0
        case (nil, _): return -1
        case (_, nil): return 1
        case (let l?, let r?): if l != r { return l < r ? -1 : 1 }
        }
    }
}
