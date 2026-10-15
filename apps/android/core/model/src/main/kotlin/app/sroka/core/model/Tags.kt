package app.sroka.core.model

import java.text.Normalizer
import java.util.Locale

private val WHITESPACE = Regex("\\s+")

/** NFC, trimmed, internal whitespace collapsed (port of shared `normalizeTagName`). */
fun normalizeTagName(name: String): String =
    Normalizer.normalize(name, Normalizer.Form.NFC).trim().replace(WHITESPACE, " ")

/** Case-insensitive identity of a tag (port of shared `tagKey`; full Unicode lower-casing). */
fun tagKey(name: String): String = normalizeTagName(name).lowercase(Locale.ROOT)

/** Max length of a tag name (api.md §14). */
const val MAX_TAG_LENGTH = 64

/** Max tags per item (api.md §14). */
const val MAX_TAGS_PER_ITEM = 100

/** Max length of an item title (api.md §14). */
const val MAX_TITLE_LENGTH = 1000

/** Max length of a saved URL (api.md §14). */
const val MAX_URL_LENGTH = 4096

/**
 * Title as stored locally and sent on the wire: trimmed, at most [MAX_TITLE_LENGTH] UTF-16 units
 * (never splitting a surrogate pair), null when empty.
 */
fun clampTitle(title: String?): String? {
    var t = title?.trim() ?: return null
    if (t.length > MAX_TITLE_LENGTH) {
        var end = MAX_TITLE_LENGTH
        if (Character.isHighSurrogate(t[end - 1])) end--
        t = t.substring(0, end).trimEnd()
    }
    return t.takeIf { it.isNotEmpty() }
}
