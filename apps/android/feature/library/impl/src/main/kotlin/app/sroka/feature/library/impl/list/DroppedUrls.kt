package app.sroka.feature.library.impl.list

import app.sroka.core.model.UrlNormalizer
import app.sroka.core.model.extractFirstUrl

/** MIME types the list accepts as a drag payload (R15.1). */
internal val DROP_MIME_TYPES = setOf("text/plain", "text/uri-list", "text/html", PDF_MIME)

internal const val PDF_MIME = "application/pdf"

/** One dragged `ClipData.Item`, reduced to plain strings so the extraction is testable on the JVM. */
internal data class DroppedItem(
    val text: String? = null,
    val uri: String? = null,
    val html: String? = null,
    /** A `content://` or `file://` URI (a dragged document); never an http link. */
    val documentUri: String? = null,
)

private val hrefRegex = Regex("""href\s*=\s*(?:"([^"]*)"|'([^']*)')""", RegexOption.IGNORE_CASE)

/**
 * http(s) links in a drag payload, in order and without duplicates. Per item: an http(s) URI wins,
 * then the first `href` of the HTML, then the text (a `text/uri-list` yields every line, other text
 * its first link). Non-http URIs (`content://`, `file://`) are ignored.
 */
internal fun extractDroppedUrls(items: List<DroppedItem>): List<String> =
    items.flatMap { item ->
        val uri = item.uri?.trim()?.takeIf { UrlNormalizer.isHttpUrl(it) }
        when {
            uri != null -> listOf(uri)
            else -> listOfNotNull(item.html?.let(::firstHref)).ifEmpty { fromText(item.text) }
        }
    }.distinct()

private fun firstHref(html: String): String? =
    hrefRegex.findAll(html)
        .map { (it.groupValues[1].ifEmpty { it.groupValues[2] }).trim() }
        .firstOrNull { UrlNormalizer.isHttpUrl(it) }

private fun fromText(text: String?): List<String> {
    if (text.isNullOrBlank()) return emptyList()
    val lines = text.lines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }
    if (lines.size > 1 && lines.all { UrlNormalizer.isHttpUrl(it) }) return lines
    return listOfNotNull(extractFirstUrl(text))
}

/**
 * Document URIs of a drag payload that is a PDF ([clipIsPdf]: the clip advertises `application/pdf`),
 * in order and without duplicates. http(s) links are not documents.
 */
internal fun extractDroppedPdfUris(items: List<DroppedItem>, clipIsPdf: Boolean): List<String> =
    if (!clipIsPdf) emptyList() else items.mapNotNull { it.documentUri?.takeIf(String::isNotBlank) }.distinct()
