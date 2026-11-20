import Foundation

/// NFC, trimmed, internal whitespace collapsed to single spaces (port of shared `normalizeTagName`). Whitespace is
/// JavaScript's (`trim()` and `\s`), not Foundation's, so the result matches what the server computes.
public func normalizeTagName(_ name: String) -> String {
    var words: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in name.precomposedStringWithCanonicalMapping.unicodeScalars {
        if isJsWhitespace(scalar) {
            if !current.isEmpty {
                words.append(String(current))
                current = String.UnicodeScalarView()
            }
        } else {
            current.append(scalar)
        }
    }
    if !current.isEmpty { words.append(String(current)) }
    return words.joined(separator: " ")
}

/// Case-insensitive identity of a tag (port of shared `tagKey`): `normalizeTagName` then locale-independent
/// full Unicode lower-casing (`toLowerCase`, including the final-sigma rule). Never uses the user's locale.
public func tagKey(_ name: String) -> String {
    jsLowercased(normalizeTagName(name))
}
