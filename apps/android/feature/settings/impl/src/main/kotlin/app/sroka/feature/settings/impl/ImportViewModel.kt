package app.sroka.feature.settings.impl

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.sroka.core.domain.DataTransferRepository
import app.sroka.core.domain.ImportError
import app.sroka.core.domain.ImportStartResult
import app.sroka.core.model.ImportFormat
import app.sroka.core.model.ImportJob
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

enum class ImportSource { POCKET, INSTAPAPER, BROWSER }

/** Maps the chosen source and the picked file name to the server format (RULINGS R11). */
fun resolveImportFormat(source: ImportSource, fileName: String?): ImportFormat = when (source) {
    ImportSource.POCKET -> {
        val name = fileName.orEmpty().lowercase()
        if (name.endsWith(".html") || name.endsWith(".htm")) ImportFormat.POCKET_HTML else ImportFormat.POCKET_CSV
    }
    ImportSource.INSTAPAPER -> ImportFormat.INSTAPAPER_CSV
    ImportSource.BROWSER -> ImportFormat.NETSCAPE_HTML
}

/** MIME types offered to the system picker; the wildcard is last because providers often report CSV as octet-stream. */
fun importMimeTypes(source: ImportSource): Array<String> = when (source) {
    ImportSource.POCKET -> arrayOf("text/csv", "application/zip", "text/html", "*/*")
    ImportSource.INSTAPAPER -> arrayOf("text/csv", "text/comma-separated-values", "*/*")
    ImportSource.BROWSER -> arrayOf("text/html", "*/*")
}

data class ImportUiState(
    val source: ImportSource = ImportSource.POCKET,
    val fileName: String? = null,
    val fileSizeBytes: Long? = null,
    val error: ImportError? = null,
    val uploading: Boolean = false,
    /** The active (possibly finished) job, if any. */
    val job: ImportJob? = null,
) {
    val hasFile: Boolean get() = fileName != null
    val jobRunning: Boolean get() = job != null && !job.status.isFinished
    val canImport: Boolean get() = hasFile && !uploading && !jobRunning
}

@HiltViewModel
class ImportViewModel @Inject constructor(
    private val transfer: DataTransferRepository,
) : ViewModel() {

    private data class Local(
        val source: ImportSource = ImportSource.POCKET,
        val uri: String? = null,
        val fileName: String? = null,
        val sizeBytes: Long? = null,
        val error: ImportError? = null,
        val uploading: Boolean = false,
    )

    private val local = MutableStateFlow(Local())

    init {
        // A job that is not finished but has no poll worker (signed-out/gave up) would stay locked forever.
        viewModelScope.launch {
            transfer.activeImport()
                .mapNotNull { job -> job?.takeIf { !it.status.isFinished }?.id }
                .distinctUntilChanged()
                .collect { transfer.resumeTracking(it) }
        }
    }

    val state: StateFlow<ImportUiState> = combine(local, transfer.activeImport()) { l, job ->
        ImportUiState(l.source, l.fileName, l.sizeBytes, l.error, l.uploading, job)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ImportUiState())

    fun selectSource(source: ImportSource) = local.update { it.copy(source = source, error = null) }

    /** Called with the picker result; null (cancelled) keeps the current file. */
    fun onFilePicked(uri: String?) {
        if (uri == null) return
        val info = transfer.fileInfo(uri)
        local.update {
            it.copy(uri = uri, fileName = info?.name ?: uri.substringAfterLast('/'), sizeBytes = info?.sizeBytes, error = null)
        }
    }

    fun startImport() {
        val l = local.value
        val uri = l.uri ?: return
        if (l.uploading || state.value.jobRunning) return
        if ((l.sizeBytes ?: 0L) > DataTransferRepository.MAX_IMPORT_BYTES) {
            local.update { it.copy(error = ImportError.TOO_LARGE) }
            return
        }
        local.update { it.copy(uploading = true, error = null) }
        viewModelScope.launch {
            val result = transfer.startImport(uri, resolveImportFormat(l.source, l.fileName))
            local.update {
                when (result) {
                    is ImportStartResult.Started -> it.copy(uploading = false)
                    is ImportStartResult.Failed -> it.copy(uploading = false, error = result.reason)
                }
            }
        }
    }

    /** "Done" on a finished job: forget it and reset the picker. */
    fun dismiss() {
        viewModelScope.launch {
            transfer.dismissImport()
            local.update { Local(source = it.source) }
        }
    }
}
