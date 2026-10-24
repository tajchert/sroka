package app.sroka.feature.library.impl.search

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.paging.PagingData
import androidx.paging.cachedIn
import app.sroka.core.domain.LibraryRepository
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SearchResult
import app.sroka.core.model.SearchScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn

/** Full-screen search over the local FTS index (R8). Works offline. */
@OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
@HiltViewModel
class SearchViewModel @Inject constructor(
    private val library: LibraryRepository,
) : ViewModel() {

    private val _query = MutableStateFlow("")
    private val _scope = MutableStateFlow(SearchScope.ALL)
    private var scopeInitialised = false

    val query: StateFlow<String> = _query
    val scope: StateFlow<SearchScope> = _scope

    /** Preselects the chip for the tab the search was opened from; only the first call counts. */
    fun initScope(tab: LibraryTab) {
        if (scopeInitialised) return
        scopeInitialised = true
        _scope.value = tab.toSearchScope()
    }

    fun onQueryChange(text: String) {
        _query.value = text
    }

    fun onScopeChange(scope: SearchScope) {
        _scope.value = scope
    }

    /** Debounced results; a blank query yields no repository call and an empty page. */
    val results: Flow<PagingData<SearchResult>> = combine(
        _query.debounce { if (it.isBlank()) 0L else DEBOUNCE_MS }.map { it.trim() }.distinctUntilChanged(),
        _scope,
    ) { q, s -> q to s }
        .distinctUntilChanged()
        .flatMapLatest { (q, s) -> if (q.isEmpty()) flowOf(PagingData.empty()) else library.search(q, s) }
        .cachedIn(viewModelScope)

    /** Total hits for the current query and scope; null while unknown (blank query or not counted yet). */
    val resultCount: StateFlow<Int?> = combine(
        _query.debounce { if (it.isBlank()) 0L else DEBOUNCE_MS }.map { it.trim() }.distinctUntilChanged(),
        _scope,
    ) { q, s -> q to s }
        .distinctUntilChanged()
        .flatMapLatest { (q, s) ->
            if (q.isEmpty()) {
                flowOf(null)
            } else {
                library.searchCount(q, s).map<Int, Int?> { it }.onStart { emit(null) }
            }
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    companion object {
        const val DEBOUNCE_MS = 250L
    }
}

internal fun LibraryTab.toSearchScope(): SearchScope = when (this) {
    LibraryTab.MY_LIST -> SearchScope.ALL
    LibraryTab.ARCHIVE -> SearchScope.ARCHIVE
    LibraryTab.FAVORITES -> SearchScope.FAVORITES
}
