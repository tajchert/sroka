import Testing

@testable import SrokaCore

/// Mirrors the tag cases of `packages/shared/src/contract.test.ts` and `normalizeTagName` in `model.ts`.
struct TagNameTests {
    @Test func `Key folds non-ASCII case`() {
        #expect(tagKey("  Żółw ") == tagKey("żółw"))
        #expect(tagKey("Éte") == "éte")
        #expect(tagKey("Machine   Learning") == "machine learning")
    }

    @Test func `Name is trimmed and whitespace collapsed`() {
        #expect(normalizeTagName("  Machine   Learning ") == "Machine Learning")
        #expect(normalizeTagName("a\t\nb") == "a b")
        #expect(normalizeTagName("   ") == "")
    }

    @Test func `Name uses JavaScript whitespace`() {
        #expect(normalizeTagName("\u{00A0}a\u{3000}b\u{FEFF}") == "a b")
        // U+0085 is not JavaScript whitespace, so it stays inside the name.
        #expect(normalizeTagName("a\u{0085}b") == "a\u{0085}b")
    }

    @Test func `Name is NFC`() {
        #expect(normalizeTagName("e\u{0301}") == "\u{00E9}")
        #expect(tagKey("E\u{0301}") == "\u{00E9}")
    }

    @Test func `Key uses full Unicode lower-casing without a locale`() {
        #expect(tagKey("İ") == "i\u{0307}")
        #expect(tagKey("TITLE") == "title")
        #expect(tagKey("ΟΔΟΣ") == "οδος")
        #expect(tagKey("Σ") == "σ")
        #expect(tagKey("ΑΣ Β") == "ας β")
    }
}
