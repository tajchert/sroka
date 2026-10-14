package app.sroka.core.database

/**
 * Builds a safe FTS4 MATCH expression from free user text (DECISIONS A4).
 *
 * Every run of letters/digits becomes a quoted prefix term (`"term*"`, FTS4 syntax), terms are AND-ed (implicit).
 * All other characters (quotes, `* ( ) : ^ - + .` ...) act as separators, so FTS operators and
 * keywords (`AND`, `OR`, `NOT`, `NEAR`) can never be interpreted; quoted they are plain words.
 * Mirrors what the unicode61 tokenizer does with the same punctuation.
 */
object FtsQuery {
    const val MAX_TERMS = 8
    const val MAX_TERM_LENGTH = 64

    /** The MATCH expression, or null when [input] has no searchable term. */
    fun build(input: String): String? {
        val terms = ArrayList<String>()
        val current = StringBuilder()
        fun flush() {
            if (current.isNotEmpty() && terms.size < MAX_TERMS) {
                terms += "\"${current.take(MAX_TERM_LENGTH)}*\""
            }
            current.setLength(0)
        }
        var i = 0
        while (i < input.length) {
            val cp = input.codePointAt(i)
            if (isTokenChar(cp)) current.appendCodePoint(cp) else flush()
            i += Character.charCount(cp)
        }
        flush()
        return terms.takeIf { it.isNotEmpty() }?.joinToString(" ")
    }

    private fun isTokenChar(cp: Int): Boolean = Character.isLetterOrDigit(cp) ||
        Character.getType(cp).let {
            it == Character.NON_SPACING_MARK.toInt() || it == Character.COMBINING_SPACING_MARK.toInt()
        }
}
