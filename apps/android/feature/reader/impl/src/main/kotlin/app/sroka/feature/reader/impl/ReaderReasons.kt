package app.sroka.feature.reader.impl

/** Plain-language reason a page could not be saved as text (shared vocabulary with web and the extension). */
enum class FailureReason { BOT_WALL, PAYWALLED, GONE, NO_RESPONSE, TOO_LARGE, NOT_ARTICLE }

/**
 * Maps the server's `parseError` code to a [FailureReason]; null for anything else (no reason sentence is shown).
 * The raw code itself is never shown to the user.
 */
fun failureReason(parseError: String?): FailureReason? {
    val code = parseError?.trim()?.lowercase().orEmpty()
    return when {
        code == "bot_wall" || code == "render_bot_wall" -> FailureReason.BOT_WALL
        code == "paywalled" -> FailureReason.PAYWALLED
        code == "http_404" || code == "http_410" -> FailureReason.GONE
        code.startsWith("http_") || code == "timeout" || code == "network" ||
            code == "too_many_redirects" || code == "bad_redirect" -> FailureReason.NO_RESPONSE
        code == "too_large" || code == "render_too_large" || code == "pdf_too_large" -> FailureReason.TOO_LARGE
        code == "not_html" -> FailureReason.NOT_ARTICLE
        else -> null
    }
}

/** A partial copy of a paywalled page only holds the teaser: "Preview only" instead of "Partial copy". */
fun isPreviewOnly(parseError: String?): Boolean = parseError?.trim()?.lowercase() == "paywalled"
