package app.sroka.core.network

import app.sroka.core.model.ExportFormat
import kotlinx.serialization.Serializable
import java.net.URLDecoder
import java.time.LocalDate

/** api.md §4.3. */
@Serializable
data class JobDto(
    val id: String,
    val kind: String? = null,
    val status: String,
    val format: String? = null,
    val total: Int? = null,
    val done: Int = 0,
    val skipped: Int = 0,
    val error: String? = null,
    val createdAt: Long = 0,
    val updatedAt: Long = 0,
)

@Serializable
internal data class JobEnvelope(val job: JobDto)

/** A finished export download: the file is at the `dest` given to [SrokaApi.export]. */
data class ExportFileDto(val fileName: String, val bytes: Long)

private val FILENAME_STAR = Regex("""filename\*\s*=\s*UTF-8''([^;]+)""", RegexOption.IGNORE_CASE)
private val FILENAME_PLAIN = Regex("""filename\s*=\s*(?:"([^"]*)"|([^;\s]+))""", RegexOption.IGNORE_CASE)

/** File name from a `Content-Disposition` header, reduced to a bare name; falls back to `sroka-export-YYYY-MM-DD.ext`. */
internal fun exportFileName(header: String?, format: ExportFormat, today: LocalDate = LocalDate.now()): String {
    val raw = header?.let { h ->
        FILENAME_STAR.find(h)?.groupValues?.get(1)
            ?.let { runCatching { URLDecoder.decode(it.replace("+", "%2B"), "UTF-8") }.getOrNull() }
            ?: FILENAME_PLAIN.find(h)?.let { m -> m.groupValues[1].ifEmpty { m.groupValues[2] } }
    }
    val clean = raw?.substringAfterLast('/')?.substringAfterLast('\\')?.trim()
        ?.takeIf { it.isNotEmpty() && it != ".." && it != "." }
    return clean ?: "sroka-export-$today.${format.extension}"
}
