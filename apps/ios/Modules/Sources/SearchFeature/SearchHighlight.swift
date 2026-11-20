import Foundation
import SrokaCore

/// Pure helpers for the result rows: the "In title / In text" label and the highlight ranges.
enum SearchHighlight {
    /// Longest term and most terms the index uses (`docs`: at most 8 terms of 64 characters).
    static let maxTerms = 8

    /// Where the query matched, in Android's words; archived results are prefixed "Archive ·".
    static func matchLabel(_ matchIn: MatchIn, archived: Bool) -> LocalizedStringResource {
        switch (archived, matchIn) {
        case (true, .text): LocalizedStringResource("Archive · in text", bundle: #bundle)
        case (true, .title): LocalizedStringResource("Archive · in title", bundle: #bundle)
        case (true, .both): LocalizedStringResource("Archive · title and text", bundle: #bundle)
        case (false, .text): LocalizedStringResource("In text", bundle: #bundle)
        case (false, .title): LocalizedStringResource("In title", bundle: #bundle)
        case (false, .both): LocalizedStringResource("Title and text", bundle: #bundle)
        }
    }

    /// The snippet's matched ranges. `highlights` are UTF-16 offsets; out-of-bounds ranges are
    /// clamped, empty ones dropped.
    static func snippetRanges(snippet: String, highlights: [Range<Int>]) -> [Range<String.Index>] {
        let count = snippet.utf16.count
        return highlights.compactMap { range in
            let start = max(range.lowerBound, 0)
            let end = min(range.upperBound, count)
            guard start < end else { return nil }
            return String.Index(utf16Offset: start, in: snippet)..<String.Index(utf16Offset: end, in: snippet)
        }
    }

    /// Matched words of the title: each query term as a prefix of a word, like the index does.
    /// Only titles that matched in the title are highlighted.
    static func titleRanges(title: String, query: String, matchIn: MatchIn) -> [Range<String.Index>] {
        guard matchIn != .text else { return [] }
        var ranges: [Range<String.Index>] = []
        for term in terms(of: query) {
            var searchStart = title.startIndex
            while searchStart < title.endIndex,
                let found = title.range(
                    of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<title.endIndex)
            {
                if startsWord(found.lowerBound, in: title) { ranges.append(found) }
                searchStart = found.upperBound
            }
        }
        return merged(ranges)
    }

    /// Runs of letters or digits, at most `maxTerms` of 64 characters.
    static func terms(of query: String) -> [String] {
        var terms: [String] = []
        var current = ""
        for character in query {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                terms.append(current)
                current = ""
            }
        }
        if !current.isEmpty { terms.append(current) }
        return Array(terms.prefix(maxTerms)).map { String($0.prefix(64)) }
    }

    private static func startsWord(_ index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return !(previous.isLetter || previous.isNumber)
    }

    /// Sorted, overlapping ranges joined.
    private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
