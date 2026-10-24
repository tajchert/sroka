package app.sroka.core.domain

import app.sroka.core.model.ExportFormat
import app.sroka.core.model.ImportFormat
import app.sroka.core.model.ImportJob
import kotlinx.coroutines.flow.Flow

/** Why an import could not be started; mapped to string resources in the UI. */
enum class ImportError {
    /** Over 20 MiB (client check or 413). */
    TOO_LARGE,

    /** 429: daily import limit reached. */
    RATE_LIMITED,

    /** Unreadable or empty file, or the server rejected it (400/415). */
    BAD_FILE,

    /** 5xx, e.g. 503 `workflow_unavailable`. */
    UNAVAILABLE,
    NETWORK,
    SIGNED_OUT,
    UNKNOWN,
}

sealed interface ImportStartResult {
    data class Started(val job: ImportJob) : ImportStartResult
    data class Failed(val reason: ImportError) : ImportStartResult
}

enum class ExportError { NETWORK, SIGNED_OUT, SERVER }

sealed interface ExportResult {
    /** [path] is an absolute file under `cacheDir/exports/`. */
    data class Ready(val path: String, val fileName: String, val bytes: Long) : ExportResult
    data class Failed(val reason: ExportError) : ExportResult
}

/** Display name and size (bytes, null when unknown) of a picked document. */
data class PickedFile(val name: String, val sizeBytes: Long?)

/**
 * Online-only import/export (RULINGS R11); an explicit exception to "network only in SyncEngine/ContentStore".
 */
interface DataTransferRepository {
    /** Copies the content [uri] to the cache, uploads it, stores the job as active and starts progress polling. */
    suspend fun startImport(uri: String, format: ImportFormat): ImportStartResult

    /** The last started import, kept up to date by the progress worker; null when none (or dismissed). */
    fun activeImport(): Flow<ImportJob?>

    /** Forget the active job once the UI has shown it finished. */
    suspend fun dismissImport()

    /** Downloads the export into `cacheDir/exports/` (older exports are deleted first). */
    suspend fun export(format: ExportFormat): ExportResult

    /** Name and size of a picked document, or null when it cannot be queried. */
    fun fileInfo(uri: String): PickedFile?

    companion object {
        /** Server cap for an import upload (api.md §11.1). */
        const val MAX_IMPORT_BYTES: Long = 20L * 1024 * 1024
    }
}
