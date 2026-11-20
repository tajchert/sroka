import Foundation
import SrokaCore

/// Finds the web address in pasted, shared or dropped text.
///
/// Mirrors `extractFirstUrl` in `packages/shared/src/url.ts` (first http(s) URL, trailing
/// punctuation and unbalanced closing brackets stripped).
/// TODO: switch to `UrlNormalizer.extractFirstUrl` once stream A lands it.
enum LinkExtraction {
    private static let trailingPunctuation = Set(".,;:!?'\"»”’…")
    private static let brackets: [(open: Character, close: Character)] = [("(", ")"), ("[", "]"), ("{", "}")]
    private static let terminators = Set(" \t\n\r<>\"'`")

    /// The first http(s) URL in `text`, or nil.
    static func firstURL(in text: String) -> String? {
        guard let range = text.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        var candidate = String(text[range.lowerBound...].prefix { !terminators.contains($0) && !$0.isWhitespace })
        while true {
            let before = candidate
            while let last = candidate.last, trailingPunctuation.contains(last) { candidate.removeLast() }
            for (open, close) in brackets where candidate.last == close {
                let opens = candidate.filter { $0 == open }.count
                let closes = candidate.filter { $0 == close }.count
                if closes > opens { candidate.removeLast() }
            }
            if candidate == before { break }
        }
        return isHTTPURL(candidate) ? candidate : nil
    }

    /// What the user typed or pasted: the first URL inside text, else the trimmed text itself when
    /// it is a web address. Nil means "not a valid web address".
    static func link(from raw: String) -> String? {
        if let found = firstURL(in: raw) { return found }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isHTTPURL(trimmed) ? trimmed : nil
    }

    static func isHTTPURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        return UrlNormalizer.hostOf(text) != nil
    }
}
