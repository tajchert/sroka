/// Builds a safe FTS5 MATCH expression from free user text (DECISIONS A4; Android `FtsQuery.kt`).
///
/// Every run of letters, digits and combining marks becomes a quoted prefix term `"term"*` (FTS5
/// syntax; Android's FTS4 writes `"term*"`), joined with `AND`. Every other character (quotes,
/// `* ( ) : ^ - + .`, …) separates terms, so FTS operators and keywords (`AND`, `OR`, `NOT`, `NEAR`)
/// are never interpreted: quoted, they are plain words.
public enum FtsQuery {
    public static let maxTerms = 8
    /// Unicode scalars per term.
    public static let maxTermLength = 64

    /// The MATCH expression, or nil when `input` has no searchable term.
    public static func build(_ input: String) -> String? {
        let terms = self.terms(input)
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    /// The bare terms `build` quotes, at most `maxTerms` of at most `maxTermLength` scalars each.
    public static func terms(_ input: String) -> [String] {
        var terms: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty, terms.count < maxTerms {
                terms.append(String(String.UnicodeScalarView(current.prefix(maxTermLength))))
            }
            current = String.UnicodeScalarView()
        }
        for scalar in input.unicodeScalars {
            if isTokenScalar(scalar) { current.append(scalar) } else { flush() }
        }
        flush()
        return terms
    }

    /// Java's `isLetterOrDigit` plus non-spacing and spacing combining marks (parity with Android).
    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .nonspacingMark, .spacingMark:
            true
        default:
            false
        }
    }
}
