import SrokaCore

/// Pure tag-entry rules of the editor (Android `TagEditorSheet.kt`: `addTag`, `tagSuggestions`).
enum TagRules {
    /// Most suggestion chips shown under the field.
    static let maxSuggestions = 8

    /// `raw` normalised and cut to `Limits.maxTagLength`.
    static func clean(_ raw: String) -> String {
        String(normalizeTagName(raw).prefix(Limits.maxTagLength))
    }

    /// Adds `raw` to `tags` (normalised, deduplicated by `tagKey`, capped at `Limits.maxTagsPerItem`).
    /// Returns `tags` unchanged when `raw` is unusable.
    static func add(_ tags: [String], _ raw: String) -> [String] {
        let name = clean(raw)
        guard !name.isEmpty, tags.count < Limits.maxTagsPerItem,
            !tags.contains(where: { tagKey($0) == tagKey(name) })
        else { return tags }
        return tags + [name]
    }
}

/// Suggestion chips under the field: an optional "Create" chip, then matching existing tags.
struct TagSuggestions: Sendable, Hashable {
    /// The normalised typed text, only when it is non-empty and neither chosen yet nor an exact
    /// (case-insensitive) match of a known tag.
    var create: String?
    /// Known tags not yet chosen whose name contains the typed text (prefix matches first).
    var existing: [String]

    var isEmpty: Bool { create == nil && existing.isEmpty }

    init(create: String? = nil, existing: [String] = []) {
        self.create = create
        self.existing = existing
    }

    init(draft: String, tags: [String], known: [String], limit: Int = TagRules.maxSuggestions) {
        let typed = TagRules.clean(draft)
        let key = tagKey(typed)
        let chosen = Set(tags.map(tagKey))
        var seen = Set<String>()
        let candidates = known.filter { seen.insert(tagKey($0)).inserted && !chosen.contains(tagKey($0)) }
        let matching: [String]
        if key.isEmpty {
            matching = candidates
        } else {
            let hits = candidates.filter { tagKey($0).contains(key) }
            matching = hits.filter { tagKey($0).hasPrefix(key) } + hits.filter { !tagKey($0).hasPrefix(key) }
        }
        let isNew = !typed.isEmpty && !chosen.contains(key) && !known.contains { tagKey($0) == key }
        self.init(create: isNew ? typed : nil, existing: Array(matching.prefix(limit)))
    }
}
