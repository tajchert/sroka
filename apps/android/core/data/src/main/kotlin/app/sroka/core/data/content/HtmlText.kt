package app.sroka.core.data.content

/** Plain text of an article document for the FTS `body` column (DECISIONS A9; no HTML parser dependency). */
internal object HtmlText {
    /** Upper bound of indexed characters per article. */
    const val MAX_CHARS = 300_000

    private val DROP_BLOCKS = Regex(
        "<(script|style|head|template|noscript)\\b[^>]*>.*?</\\1\\s*>",
        setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
    )
    private val COMMENTS = Regex("<!--.*?-->", RegexOption.DOT_MATCHES_ALL)
    private val TAGS = Regex("<[^>]*>")
    private val ENTITY = Regex("&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});")
    private val WHITESPACE = Regex("\\s+")

    private val NAMED = mapOf(
        "amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to " ",
        "ndash" to "–", "mdash" to "—", "hellip" to "…", "lsquo" to "‘", "rsquo" to "’",
        "ldquo" to "“", "rdquo" to "”", "laquo" to "«", "raquo" to "»", "copy" to "©",
        "shy" to "", "zwj" to "", "zwnj" to "", "thinsp" to " ", "ensp" to " ", "emsp" to " ",
    )

    fun extract(html: String): String {
        val noBlocks = html.replace(COMMENTS, " ").replace(DROP_BLOCKS, " ")
        val text = decodeEntities(noBlocks.replace(TAGS, " "))
        val collapsed = text.replace(WHITESPACE, " ").trim()
        return if (collapsed.length > MAX_CHARS) collapsed.substring(0, MAX_CHARS) else collapsed
    }

    fun decodeEntities(s: String): String = ENTITY.replace(s) { m ->
        val body = m.groupValues[1]
        when {
            body.startsWith("#x") || body.startsWith("#X") -> codePoint(body.substring(2).toIntOrNull(16)) ?: m.value
            body.startsWith("#") -> codePoint(body.substring(1).toIntOrNull()) ?: m.value
            else -> NAMED[body] ?: m.value
        }
    }

    private fun codePoint(cp: Int?): String? =
        cp?.takeIf { it in 1..0x10FFFF && it !in 0xD800..0xDFFF }?.let { String(Character.toChars(it)) }
}
