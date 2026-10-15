package app.sroka.feature.library.impl.tags

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.sroka.core.domain.TagEditResult
import app.sroka.core.domain.TagRepository
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
) : ViewModel() {

    val uiState: StateFlow<TagsUiState> = repository.observeTags()
        .map { TagsUiState(it) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), TagsUiState())

    /** Returns true when renamed (or merged); false when [to] is not a valid tag name. */
    suspend fun rename(from: String, to: String): Boolean = repository.rename(from, to) == TagEditResult.Done

    fun delete(name: String) {
        viewModelScope.launch { repository.delete(name) }
    }
}
