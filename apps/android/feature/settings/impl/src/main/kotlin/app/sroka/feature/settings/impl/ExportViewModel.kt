package app.sroka.feature.settings.impl

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.sroka.core.domain.DataTransferRepository
import app.sroka.core.domain.ExportError
import app.sroka.core.domain.ExportResult
import app.sroka.core.model.ExportFormat
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class ReadyExport(val path: String, val fileName: String, val bytes: Long)

data class ExportUiState(
    val format: ExportFormat = ExportFormat.JSON,
    val exporting: Boolean = false,
    val ready: ReadyExport? = null,
    val error: ExportError? = null,
)

/** MIME type for sharing/saving an export. */
fun exportMimeType(format: ExportFormat): String = when (format) {
    ExportFormat.CSV -> "text/csv"
    ExportFormat.JSON -> "application/json"
}

@HiltViewModel
class ExportViewModel @Inject constructor(
    private val transfer: DataTransferRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(ExportUiState())
    val state: StateFlow<ExportUiState> = _state

    fun selectFormat(format: ExportFormat) {
        if (_state.value.exporting) return
        // A different format invalidates the built file.
        _state.update { it.copy(format = format, ready = null, error = null) }
    }

    fun export() {
        val format = _state.value.format
        if (_state.value.exporting) return
        _state.update { it.copy(exporting = true, ready = null, error = null) }
        viewModelScope.launch {
            val result = transfer.export(format)
            _state.update {
                when (result) {
                    is ExportResult.Ready -> it.copy(
                        exporting = false,
                        ready = ReadyExport(result.path, result.fileName, result.bytes),
                    )
                    is ExportResult.Failed -> it.copy(exporting = false, error = result.reason)
                }
            }
        }
    }
}
