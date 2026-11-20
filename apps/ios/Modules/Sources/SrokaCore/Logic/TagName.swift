import Foundation

// Foundation stream: needed by `TagCount.id` and the fakes. Stream A owns this file and adds the
// shared test vectors (`packages/shared/src/model.test.ts`).

/// NFC, trimmed, internal whitespace collapsed (port of shared `normalizeTagName`).
public func normalizeTagName(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
}

/// Case-insensitive identity of a tag (port of shared `tagKey`; full Unicode lower-casing).
public func tagKey(_ name: String) -> String {
    normalizeTagName(name).lowercased()
}
