package app.sroka.feature.library.impl.save

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.sroka.core.domain.AuthRepository
import app.sroka.core.domain.PdfUploader
import app.sroka.core.model.PdfUploadError
import app.sroka.core.model.PdfUploadState
import app.sroka.core.model.SessionState
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

sealed interface PdfShareState {
    data object Working : PdfShareState

    /** [count] files were accepted and upload in the background. */
    data class Queued(val count: Int) : PdfShareState

    /** The server answered for every queued file and at least one was already in the library. */
    data class Duplicate(val count: Int) : PdfShareState

    /** The server answered for every queued file; all are new. */
    data class Saved(val count: Int) : PdfShareState

    /** Every file was rejected on the device; [error] is the first reason. */
    data class Failed(val error: PdfUploadError) : PdfShareState

    /** The share carried no file URI. */
    data object NoFile : PdfShareState

    data object NeedsSignIn : PdfShareState
}

/** Share-target for PDFs: hands the shared URIs to [PdfUploader] (which copies them before returning). */
@HiltViewModel
class PdfShareViewModel @Inject constructor(
    private val uploader: PdfUploader,
    private val auth: AuthRepository,
) : ViewModel() {
    private val _state = MutableStateFlow<PdfShareState>(PdfShareState.Working)
    val state: StateFlow<PdfShareState> = _state
    private var started = false

    /** Enqueues [uris] once, even if called again after a configuration change. */
    fun start(uris: List<Uri>) {
        if (started) return
        started = true
        viewModelScope.launch {
            if (auth.session.first() is SessionState.SignedOut) {
                _state.value = PdfShareState.NeedsSignIn
                return@launch
            }
            if (uris.isEmpty()) {
                _state.value = PdfShareState.NoFile
                return@launch
            }
            val result = uploader.enqueue(uris)
            val failed = result.mapNotNull { (it.state as? PdfUploadState.Failed)?.error }
            _state.value = if (failed.size == result.size && failed.isNotEmpty()) {
                PdfShareState.Failed(failed.first())
            } else {
                PdfShareState.Queued(result.size - failed.size)
            }
            val ids = result.filter { it.state !is PdfUploadState.Failed }.map { it.id }.toSet()
            if (ids.isNotEmpty()) watchOutcome(ids)
        }
    }

    /** Moves Queued to Saved / Duplicate once every accepted upload has finished on the server. */
    private suspend fun watchOutcome(ids: Set<String>) {
        val done = uploader.uploads.first { list ->
            val mine = list.filter { it.id in ids }
            mine.size == ids.size && mine.none { it.isActive }
        }.filter { it.id in ids }
        val finished = done.filter { it.state is PdfUploadState.Done }
        if (finished.isEmpty()) return
        val dup = finished.count { (it.state as PdfUploadState.Done).duplicate }
        _state.value = if (dup > 0) PdfShareState.Duplicate(dup) else PdfShareState.Saved(finished.size)
    }
}
