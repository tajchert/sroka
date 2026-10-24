package app.sroka.feature.library.impl.tags

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.sroka.core.domain.AuthRepository
import app.sroka.core.domain.TagEditResult
import app.sroka.core.domain.TagRepository
import app.sroka.core.model.SessionState
import app.sroka.core.model.TagCount
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** Tags tab state: null while loading, then the tag list. */
data class TagsUiState(val tags: List<TagCount>? = null)

@HiltViewModel
class TagsViewModel @Inject constructor(
    private val repository: TagRepository,
    auth: AuthRepository,
) : ViewModel() {

    val uiState: StateFlow<TagsUiState> = repository.observeTags()
        .map { TagsUiState(it) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), TagsUiState())

    /** First letter of the signed-in email, upper-cased, for the avatar; null when unknown. */
    val avatarLetter: StateFlow<String?> = auth.session
        .map { (it as? SessionState.SignedIn)?.email?.trim()?.firstOrNull()?.uppercaseChar()?.toString() }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    /** Returns true when renamed (or merged); false when [to] is not a valid tag name. */
    suspend fun rename(from: String, to: String): Boolean = repository.rename(from, to) == TagEditResult.Done

    fun delete(name: String) {
        viewModelScope.launch { repository.delete(name) }
    }
}
