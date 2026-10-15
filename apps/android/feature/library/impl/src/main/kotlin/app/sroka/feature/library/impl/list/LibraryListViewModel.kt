package app.sroka.feature.library.impl.list

import androidx.annotation.StringRes
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.paging.PagingData
import androidx.paging.cachedIn
import app.sroka.core.domain.AuthRepository
import app.sroka.core.domain.LibraryRepository
import app.sroka.core.domain.SaveSource
import app.sroka.core.domain.SettingsRepository
import app.sroka.core.domain.SyncController
import app.sroka.core.domain.SyncEvent
import app.sroka.core.domain.SyncStatusRepository
import app.sroka.core.domain.TagRepository
import app.sroka.core.model.Item
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SaveResult
import app.sroka.core.model.SessionState
import app.sroka.core.model.SortOrder
import app.sroka.core.model.SyncErrorKind
import app.sroka.core.model.SyncPhase
import app.sroka.core.model.SyncStatus
import app.sroka.core.model.UrlNormalizer
import app.sroka.core.model.extractFirstUrl
import app.sroka.feature.library.impl.R
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** What a list screen shows: a top-level tab or all items with one tag. */
sealed interface ListScope {
    data class Tab(val tab: LibraryTab) : ListScope

    data class Tag(val name: String) : ListScope
}

/** Typed screen state (the paged rows are exposed separately as [LibraryListViewModel.items]). */
data class LibraryListUiState(
    val sort: SortOrder = SortOrder.NEWEST,
    val searchText: String = "",
    val sync: SyncStatus = SyncStatus(),
    /** The session expired: show the "sign in again" banner. */
    val needsSignIn: Boolean = false,
) {
    /** True while a sync or download is running. */
    val busy: Boolean get() = sync.phase is SyncPhase.Syncing || sync.phase is SyncPhase.Downloading
}

/** One-shot UI messages shown as snackbars. */
sealed interface ListEvent {
    data class Undoable(@StringRes val message: Int, val undo: UndoAction) : ListEvent

    data class Info(@StringRes val message: Int) : ListEvent
}

/** Reverts a swipe action. */
sealed interface UndoAction {
    data class Status(val id: String, val previous: ItemStatus) : UndoAction

    data class Favorite(val id: String, val previous: Boolean) : UndoAction
}

@OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
@HiltViewModel
class LibraryListViewModel @Inject constructor(
    private val library: LibraryRepository,
    private val tags: TagRepository,
    private val sync: SyncController,
    syncStatus: SyncStatusRepository,
    auth: AuthRepository,
    private val settings: SettingsRepository,
) : ViewModel() {

    private val scope = MutableStateFlow<ListScope?>(null)
    private val searchText = MutableStateFlow("")
    private val selectedId = MutableStateFlow<String?>(null)
    private val eventChannel = Channel<ListEvent>(Channel.BUFFERED)

    /** Sets what this screen lists. Idempotent; the ViewModel is per navigation entry. */
    fun setScope(value: ListScope) {
        scope.value = value
    }

    private val sort = settings.preferences.map { it.sortOrder }.distinctUntilChanged()

    val uiState: StateFlow<LibraryListUiState> = combine(
        sort,
        searchText,
        syncStatus.status,
        auth.session,
    ) { sortOrder, text, status, session ->
        LibraryListUiState(
            sort = sortOrder,
            searchText = text,
            sync = status,
            needsSignIn = session is SessionState.Expired ||
                (status.phase as? SyncPhase.Error)?.kind == SyncErrorKind.AUTH,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), LibraryListUiState())

    /** Rows for the current scope, sort and (debounced) search text. */
    val items: Flow<PagingData<ItemSummary>> = combine(
        scope.filterNotNull(),
        searchText.debounce { if (it.isEmpty()) 0L else SEARCH_DEBOUNCE_MS }.map { it.trim().ifEmpty { null } },
        sort,
    ) { scope, search, sortOrder ->
        when (scope) {
            is ListScope.Tab -> ItemQuery(tab = scope.tab, search = search, sort = sortOrder)
            is ListScope.Tag -> ItemQuery(tab = LibraryTab.MY_LIST, tag = scope.name, search = search, sort = sortOrder)
        }
    }
        .distinctUntilChanged()
        .flatMapLatest { library.pagedItems(it) }
        .cachedIn(viewModelScope)

    /** Item shown in the actions sheet, kept live. */
    val selectedItem: StateFlow<Item?> = selectedId
        .flatMapLatest { id -> if (id == null) flowOf(null) else library.observeItem(id) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val recentTags: StateFlow<List<String>> = tags.observeRecentTags(RECENT_TAGS)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val events: Flow<ListEvent> = eventChannel.receiveAsFlow()

    /** Results of user-initiated fetches; collected only by the visible screen. */
    val fetchEvents: Flow<SyncEvent> = syncStatus.events

    fun onSearchTextChange(text: String) {
        searchText.value = text
    }

    fun setSort(order: SortOrder) {
        viewModelScope.launch { settings.setSortOrder(order) }
    }

    fun fetchNewArticles() = sync.fetchNewArticles()

    fun showActions(id: String) {
        selectedId.value = id
    }

    fun dismissActions() {
        selectedId.value = null
    }

    /** Swipe end to start: archive, or move back to My List when [ItemSummary.status] is archived. */
    fun toggleArchive(id: String, current: ItemStatus) {
        val target = if (current == ItemStatus.UNREAD) ItemStatus.ARCHIVED else ItemStatus.UNREAD
        viewModelScope.launch {
            library.setStatus(id, target)
            eventChannel.send(
                ListEvent.Undoable(
                    if (target == ItemStatus.ARCHIVED) R.string.feature_library_snack_archived else R.string.feature_library_snack_unarchived,
                    UndoAction.Status(id, current),
                ),
            )
        }
    }

    /** Swipe start to end: toggle favorite. */
    fun toggleFavorite(id: String, current: Boolean) {
        viewModelScope.launch {
            library.setFavorite(id, !current)
            eventChannel.send(
                ListEvent.Undoable(
                    if (!current) R.string.feature_library_snack_favorited else R.string.feature_library_snack_unfavorited,
                    UndoAction.Favorite(id, current),
                ),
            )
        }
    }

    fun undo(action: UndoAction) {
        viewModelScope.launch {
            when (action) {
                is UndoAction.Status -> library.setStatus(action.id, action.previous)
                is UndoAction.Favorite -> library.setFavorite(action.id, action.previous)
            }
        }
    }

    fun setTags(id: String, names: List<String>) {
        viewModelScope.launch { library.setTags(id, names) }
    }

    fun delete(id: String) {
        viewModelScope.launch {
            library.delete(id)
            eventChannel.send(ListEvent.Info(R.string.feature_library_snack_deleted))
        }
    }

    fun refresh(id: String) {
        viewModelScope.launch {
            library.refresh(id)
            eventChannel.send(ListEvent.Info(R.string.feature_library_snack_refresh))
        }
    }

    /**
     * Saves the link found in [raw] (typed or pasted). Returns false when there is no valid http(s)
     * URL so the dialog can show an error.
     */
    suspend fun addLink(raw: String): Boolean {
        val url = extractFirstUrl(raw) ?: raw.trim().takeIf { UrlNormalizer.isHttpUrl(it) } ?: return false
        return when (val result = library.save(url, source = SaveSource.MANUAL)) {
            is SaveResult.Saved -> {
                eventChannel.send(
                    ListEvent.Info(
                        if (result.alreadySaved) R.string.feature_library_snack_already_saved else R.string.feature_library_snack_saved,
                    ),
                )
                true
            }
            SaveResult.InvalidUrl -> false
        }
    }

    private companion object {
        const val SEARCH_DEBOUNCE_MS = 300L
        const val RECENT_TAGS = 20
    }
}
