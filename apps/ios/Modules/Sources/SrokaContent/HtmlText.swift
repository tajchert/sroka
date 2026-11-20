import Foundation

/// Plain text of an article document for the FTS `body` column (DECISIONS A9; Android `HtmlText.kt`).
/// Regex based on purpose: no HTML parser dependency, same output as Android.
public enum HtmlText {
    /// Upper bound of indexed characters (UTF-16 units, as on Android) per article.
    public static let maxChars = 300_000

    private static let dropBlocks = regex(
        #"<(script|style|head|template|noscript)\b[^>]*>.*?</\1\s*>"#,
        [.caseInsensitive, .dotMatchesLineSeparators])
    private static let comments = regex(#"<!--.*?-->"#, [.dotMatchesLineSeparators])
    private static let tags = regex(#"<[^>]*>"#)
    private static let entity = regex(#"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});"#)
    private static let whitespace = regex(#"\s+"#)

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "copy": "©",
        "shy": "", "zwj": "", "zwnj": "", "thinsp": " ", "ensp": " ", "emsp": " ",
    ]

    public static func extract(_ html: String) -> String {
        let noBlocks = replace(dropBlocks, in: replace(comments, in: html, with: " "), with: " ")
        let text = decodeEntities(replace(tags, in: noBlocks, with: " "))
        let collapsed = replace(whitespace, in: text, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let units = collapsed.utf16
        guard units.count > maxChars else { return collapsed }
        var end = units.index(units.startIndex, offsetBy: maxChars)
        // Never split a surrogate pair.
        if UTF16.isTrailSurrogate(units[end]) { end = units.index(before: end) }
        return String(collapsed[..<end])
    }

    public static func decodeEntities(_ text: String) -> String {
        let source = text as NSString
        let matches = entity.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let whole = source.substring(with: match.range)
            let body = source.substring(with: match.range(at: 1))
            let decoded: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                decoded = codePoint(Int(body.dropFirst(2), radix: 16))
            } else if body.hasPrefix("#") {
                decoded = codePoint(Int(body.dropFirst()))
            } else {
                decoded = named[body]
            }
            result += decoded ?? whole
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    private static func codePoint(_ value: Int?) -> String? {
        guard let value, (1...0x10FFFF).contains(value), !(0xD800...0xDFFF).contains(value),
            let scalar = Unicode.Scalar(UInt32(value))
        else { return nil }
        return String(Character(scalar))
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            // The patterns are constants; a failure here is a programming error caught by the tests.
            fatalError("invalid pattern \(pattern)")
        }
    }
}
