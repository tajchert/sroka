package app.sroka.core.model

/** Server import formats (api.md §11.1); [wire] is the `format` form field. */
enum class ImportFormat(val wire: String) {
    POCKET_CSV("pocket_csv"),
    POCKET_HTML("pocket_html"),
    INSTAPAPER_CSV("instapaper_csv"),
    NETSCAPE_HTML("netscape_html"),
    ;

    companion object {
        fun fromWire(value: String?): ImportFormat? = entries.firstOrNull { it.wire == value }
    }
}

/** `GET /v1/exports?format=` (api.md §11.2); [wire] is the query value, [extension] the fallback file extension. */
enum class ExportFormat(val wire: String, val extension: String) {
    CSV("csv", "csv"),
    JSON("json", "json"),
}

/** api.md §4.3: `queued -> running -> done | failed`. */
enum class JobStatus {
    QUEUED,
    RUNNING,
    DONE,
    FAILED,
    ;

    val isFinished: Boolean get() = this == DONE || this == FAILED

    companion object {
        /** Unknown future values are treated as still running. */
        fun fromWire(value: String?): JobStatus = when (value) {
            "queued" -> QUEUED
            "done" -> DONE
            "failed" -> FAILED
            else -> RUNNING
        }
    }
}

/** An import job (api.md §4.3). [total] is null until the file is parsed; [error] is a server code such as `too_many_rows`. */
data class ImportJob(
    val id: String,
    val status: JobStatus,
    val format: ImportFormat,
    val total: Int?,
    val done: Int,
    val skipped: Int,
    val error: String?,
    val createdAt: Long,
    val updatedAt: Long,
)
