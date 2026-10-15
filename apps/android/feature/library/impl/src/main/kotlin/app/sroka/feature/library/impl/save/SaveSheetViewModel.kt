package app.sroka.feature.library.impl.save

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.sroka.core.domain.AuthRepository
import app.sroka.core.domain.LibraryRepository
import app.sroka.core.domain.SaveSource
import app.sroka.core.domain.TagRepository
import app.sroka.core.model.SaveResult
import app.sroka.core.model.SessionState
import app.sroka.core.model.extractFirstUrl
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

sealed interface SaveState {
    data object Saving : SaveState

    data class Saved(val itemId: String, val alreadySaved: Boolean) : SaveState

    /** The shared text contains no http(s) link. */
    data object NoUrl : SaveState

    data object NeedsSignIn : SaveState
}

/** Share-target save (DECISIONS A11). Saves locally, so it works offline. */
@HiltViewModel
class SaveSheetViewModel @Inject constructor(
    private val library: LibraryRepository,
    tags: TagRepository,
    private val auth: AuthRepository,
) : ViewModel() {

    private val _state = MutableStateFlow<SaveState>(SaveState.Saving)
    val state: StateFlow<SaveState> = _state

    val recentTags: StateFlow<List<String>> = tags.observeRecentTags(RECENT_TAGS)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private var started = false

    /** Saves the first link in [sharedText] once, even if called again after a configuration change. */
    fun start(sharedText: String?, subject: String?) {
        if (started) return
        started = true
        viewModelScope.launch {
            if (auth.session.first() is SessionState.SignedOut) {
                _state.value = SaveState.NeedsSignIn
                return@launch
            }
            val url = sharedText?.let(::extractFirstUrl)
            if (url == null) {
                _state.value = SaveState.NoUrl
                return@launch
            }
            // Browsers put the page title in the subject; use it unless it is just a link.
            val title = subject?.trim()?.takeIf { it.isNotEmpty() && extractFirstUrl(it) == null }
            _state.value = when (val result = library.save(url, title = title, source = SaveSource.SHARE)) {
                is SaveResult.Saved -> SaveState.Saved(result.itemId, result.alreadySaved)
                SaveResult.InvalidUrl -> SaveState.NoUrl
            }
        }
    }

    /** Suspends until the tags are written, so the caller can finish the activity afterwards. */
    suspend fun setTags(itemId: String, names: List<String>) = library.setTags(itemId, names)

    private companion object {
        const val RECENT_TAGS = 20
    }
}
