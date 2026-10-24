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
import app.sroka.core.model.Item
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlin.math.ceil
import kotlin.math.roundToInt
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

/** "42% read · 6 min left" numbers for the already-saved card. [minutesLeft] is null when the length is unknown. */
data class ReadProgress(val percent: Int, val minutesLeft: Int?)

fun readProgressOf(item: Item): ReadProgress {
    val progress = item.progress.coerceIn(0f, 1f)
    val left = item.readingMinutes?.let { ceil(it * (1f - progress)).toInt() }
    return ReadProgress((progress * 100).roundToInt(), left)
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

    /** The saved item, live, so the sheet can show download state, favourite and progress. */
    @OptIn(ExperimentalCoroutinesApi::class)
    val item: StateFlow<Item?> = _state
        .flatMapLatest { s -> if (s is SaveState.Saved) library.observeItem(s.itemId) else flowOf(null) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    private val _autoDismissed = MutableStateFlow(false)

    /** Turns true when the auto-dismiss timer elapsed without any interaction; the host then finishes. */
    val autoDismissed: StateFlow<Boolean> = _autoDismissed

    private var timer: Job? = null
    private var started = false
    private var interacted = false

    private fun armTimer() {
        if (interacted) return
        timer?.cancel()
        timer = viewModelScope.launch {
            delay(AUTO_DISMISS_MS)
            _autoDismissed.value = true
        }
    }

    /** Any touch on the sheet cancels the auto-dismiss for good. */
    fun onInteraction() {
        interacted = true
        timer?.cancel()
        timer = null
    }

    fun toggleFavorite() {
        val id = (_state.value as? SaveState.Saved)?.itemId ?: return
        viewModelScope.launch {
            val current = library.observeItem(id).first() ?: return@launch
            library.setFavorite(id, !current.isFavorite)
        }
    }

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
                armTimer()
                return@launch
            }
            // Browsers put the page title in the subject; use it unless it is just a link.
            val title = subject?.trim()?.takeIf { it.isNotEmpty() && extractFirstUrl(it) == null }
            _state.value = when (val result = library.save(url, title = title, source = SaveSource.SHARE)) {
                is SaveResult.Saved -> SaveState.Saved(result.itemId, result.alreadySaved)
                SaveResult.InvalidUrl -> SaveState.NoUrl
            }
            armTimer()
        }
    }

    /** Suspends until the tags are written, so the caller can finish the activity afterwards. */
    suspend fun setTags(itemId: String, names: List<String>) = library.setTags(itemId, names)

    private companion object {
        const val RECENT_TAGS = 20
        const val AUTO_DISMISS_MS = 4_000L
    }
}
