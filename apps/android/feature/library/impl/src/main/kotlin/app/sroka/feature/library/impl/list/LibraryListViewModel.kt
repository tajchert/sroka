package app.sroka.feature.library.impl.list

import androidx.annotation.StringRes
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.paging.PagingData
import androidx.paging.cachedIn
import app.sroka.core.domain.AccountRepository
import app.sroka.core.domain.AuthRepository
import android.net.Uri
import app.sroka.core.domain.LibraryRepository
import app.sroka.core.domain.PdfUploader
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
import app.sroka.core.model.PdfUpload
import app.sroka.core.model.PdfUploadError
import app.sroka.core.model.PdfUploadState
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
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.transform
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** What a list screen shows: a top-level tab or all items with one tag. */
sealed interface ListScope {
    data class Tab(val tab: LibraryTab) : ListScope

    data class Tag(val name: String) : ListScope
}

/**
 * Home filter chips (proposal 08), combined with AND inside the selected tab: favorites only, under
 * 10 minutes, one tag. Ignored on tag pages.
 */
data class ListFilters(
    val favoritesOnly: Boolean = false,
    val underTenMinutes: Boolean = false,
    val tag: String? = null,
) {
    val active: Boolean get() = favoritesOnly || underTenMinutes || tag != null

    companion object {
        /** "Under 10 min": a known reading time of at most this many whole minutes. */
        const val UNDER_TEN_MAX_MINUTES = 9

        /** Saves the filters across rotation and process death. */
        val Saver = androidx.compose.runtime.saveable.listSaver<ListFilters, Any?>(
            save = { listOf(it.favoritesOnly, it.underTenMinutes, it.tag) },
            restore = { ListFilters(it[0] as Boolean, it[1] as Boolean, it[2] as String?) },
        )
    }
}

/** The query a list scope, its filters and the sort produce. */
internal fun listQuery(scope: ListScope, filters: ListFilters, sort: SortOrder): ItemQuery = when (scope) {
    is ListScope.Tab -> ItemQuery(
        tab = scope.tab,
        sort = sort,
        tag = filters.tag,
        favoritesOnly = filters.favoritesOnly,
        maxReadingMinutes = if (filters.underTenMinutes) ListFilters.UNDER_TEN_MAX_MINUTES else null,
    )
    is ListScope.Tag -> ItemQuery(tab = null, tag = scope.name, sort = sort)
}

/** Typed screen state (the paged rows are exposed separately as [LibraryListViewModel.items]). */
data class LibraryListUiState(
    val sort: SortOrder = SortOrder.NEWEST,
    /** Signed-in account email; the avatar shows its first letter. */
    val email: String = "",
    val sync: SyncStatus = SyncStatus(),
    /** The session expired: show the "sign in again" banner. */
    val needsSignIn: Boolean = false,
) {
    /** True while a sync or download is running. */
    val busy: Boolean get() = sync.phase is SyncPhase.Syncing || sync.phase is SyncPhase.Resyncing || sync.phase is SyncPhase.Downloading
}

/** One-shot UI messages shown as snackbars. */
sealed interface ListEvent {
    data class Undoable(@StringRes val message: Int, val undo: UndoAction) : ListEvent

    data class Info(@StringRes val message: Int) : ListEvent

    /** Links dropped into the list were saved: "Saved to Sroka" / "Saved N links" with Undo. */
    data class DropSaved(val ids: List<String>) : ListEvent

    /** The dropped link was already saved: "Already in Sroka" with Open. */
    data class DropAlready(val itemId: String) : ListEvent

    /** [count] PDFs were accepted for upload. */
    data class PdfQueued(val count: Int) : ListEvent

    /** A PDF upload finished; [duplicate] = the file was already in Sroka. */
    data class PdfDone(val duplicate: Boolean, val itemId: String?) : ListEvent

    /** A PDF upload failed permanently with a typed [error]. */
    data class PdfFailed(val error: PdfUploadError) : ListEvent
}

/** True for events that put a new item into the library (a saved link, dropped links, queued PDFs). */
internal fun ListEvent.addsNewItem(): Boolean = when (this) {
    is ListEvent.DropSaved, is ListEvent.PdfQueued -> true
    is ListEvent.Info -> message == R.string.feature_library_snack_saved
    else -> false
}

/** Snackbar text for archive/unarchive; offline adds "Syncs when you're online" (R6). */
@StringRes
internal fun archiveMessage(archived: Boolean, offline: Boolean): Int = when {
    archived && offline -> R.string.feature_library_snack_archived_offline
    archived -> R.string.feature_library_snack_archived
    offline -> R.string.feature_library_snack_unarchived_offline
    else -> R.string.feature_library_snack_unarchived
}

/** Reverts a swipe action. */
sealed interface UndoAction {
    data class Status(val id: String, val previous: ItemStatus) : UndoAction

    data class Favorite(val id: String, val previous: Boolean) : UndoAction

    /** Removes items created by a drop. */
    data class Delete(val ids: List<String>) : UndoAction
}

@OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
@HiltViewModel
class LibraryListViewModel @Inject constructor(
    private val library: LibraryRepository,
    private val tags: TagRepository,
    private val account: AccountRepository,
    private val sync: SyncController,
    syncStatus: SyncStatusRepository,
    auth: AuthRepository,
    private val settings: SettingsRepository,
    private val uploader: PdfUploader,
) : ViewModel() {

    private val scope = MutableStateFlow<ListScope?>(null)
    private val filters = MutableStateFlow(ListFilters())
    private val selectedId = MutableStateFlow<String?>(null)
    private val eventChannel = Channel<ListEvent>(Channel.BUFFERED)

    /** Sets what this screen lists. Idempotent; the ViewModel is per navigation entry. */
    fun setScope(value: ListScope) {
        scope.value = value
    }

    /** Sets the home filter chips (ignored on tag pages). */
    fun setFilters(value: ListFilters) {
        filters.value = value
    }

    private val sort = settings.preferences.map { it.sortOrder }.distinctUntilChanged()

    val uiState: StateFlow<LibraryListUiState> = combine(
        sort,
        syncStatus.status,
        auth.session,
    ) { sortOrder, status, session ->
        LibraryListUiState(
            sort = sortOrder,
            email = when (session) {
                is SessionState.SignedIn -> session.email
                is SessionState.Expired -> session.email
                SessionState.SignedOut -> ""
            },
            sync = status,
            needsSignIn = session is SessionState.Expired ||
                (status.phase as? SyncPhase.Error)?.kind == SyncErrorKind.AUTH,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), LibraryListUiState())

    /** Rows for the current scope and sort. Search lives in its own screen (`search/`). */
    val items: Flow<PagingData<ItemSummary>> = combine(
        scope.filterNotNull(),
        filters,
        sort,
        ::listQuery,
    )
        .distinctUntilChanged()
        .flatMapLatest { library.pagedItems(it) }
        .cachedIn(viewModelScope)

    /** Item shown in the actions sheet, kept live. */
    val selectedItem: StateFlow<Item?> = selectedId
        .flatMapLatest { id -> if (id == null) flowOf(null) else library.observeItem(id) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    /** "Continue reading" cards (My List without filters only; the screen decides when to show them). */
    val continueReading: StateFlow<List<ItemSummary>> = library.observeContinueReading()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    /** The most-used tags (by item count) offered as filter chips. */
    val topTags: StateFlow<List<String>> = tags.observeTags()
        .map { all -> all.filter { it.count > 0 }.sortedByDescending { it.count }.take(TOP_TAGS).map { it.name } }
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val extensionConnectedState = MutableStateFlow(false)

    /** The account has used the browser extension (`/v1/me` `clients.extension`): onboarding shows it done. */
    val extensionConnected: StateFlow<Boolean> = extensionConnectedState

    /** Re-reads which clients the account has used. Failures are silent (the step just stays open). */
    fun refreshConnectedClients() {
        if (extensionConnectedState.value) return
        viewModelScope.launch {
            if (account.connectedClients()?.extension == true) extensionConnectedState.value = true
        }
    }

    val recentTags: StateFlow<List<String>> = tags.observeRecentTags(RECENT_TAGS)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val events: Flow<ListEvent> = eventChannel.receiveAsFlow()

    /** PDF uploads, oldest first (drives the "Uploading N PDFs" cards). */
    val uploads: StateFlow<List<PdfUpload>> = uploader.uploads
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val announced = mutableSetOf<String>()

    /**
     * Snackbar events for uploads that finished or failed. Cold: collected by the visible screen only.
     * Finished entries are forgotten once announced, except while a failure is still on screen.
     */
    val uploadEvents: Flow<ListEvent> = uploader.uploads.transform { list ->
        list.forEach { upload ->
            if (upload.isActive || !announced.add(upload.id)) return@forEach
            when (val st = upload.state) {
                is PdfUploadState.Done -> emit(ListEvent.PdfDone(st.duplicate, st.itemId))
                is PdfUploadState.Failed -> emit(ListEvent.PdfFailed(st.error))
                else -> Unit
            }
        }
        if (list.any { it.state is PdfUploadState.Done } && list.none { it.state is PdfUploadState.Failed }) {
            uploader.clearFinished()
        }
    }

    /** Copies the picked/dropped PDFs into app storage and queues their upload. */
    fun addPdfs(uris: List<Uri>) {
        if (uris.isEmpty()) return
        viewModelScope.launch {
            val queued = uploader.enqueue(uris).count { it.state !is PdfUploadState.Failed }
            if (queued > 0) eventChannel.send(ListEvent.PdfQueued(queued))
        }
    }

    /** Forgets failed uploads (the card's Dismiss). */
    fun dismissUploadFailures() = uploader.clearFinished()

    /** Results of user-initiated fetches; collected only by the visible screen. */
    val fetchEvents: Flow<SyncEvent> = syncStatus.events

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
        val offline = uiState.value.sync.phase is SyncPhase.Offline
        viewModelScope.launch {
            library.setStatus(id, target)
            eventChannel.send(
                ListEvent.Undoable(
                    archiveMessage(archived = target == ItemStatus.ARCHIVED, offline = offline),
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
                is UndoAction.Delete -> action.ids.forEach { library.delete(it) }
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

    /** Saves links dragged into the list (R15.1); local-first, so it also works offline. */
    fun dropUrls(urls: List<String>) {
        viewModelScope.launch {
            if (urls.isEmpty()) {
                eventChannel.send(ListEvent.Info(R.string.feature_library_drop_no_link))
                return@launch
            }
            val created = mutableListOf<String>()
            var duplicate: String? = null
            for (url in urls) {
                when (val result = library.save(url, source = SaveSource.DRAG)) {
                    is SaveResult.Saved ->
                        if (result.alreadySaved) {
                            if (duplicate == null) duplicate = result.itemId
                        } else {
                            created += result.itemId
                        }
                    SaveResult.InvalidUrl -> Unit
                }
            }
            eventChannel.send(
                when {
                    created.isNotEmpty() -> ListEvent.DropSaved(created)
                    duplicate != null -> ListEvent.DropAlready(duplicate)
                    else -> ListEvent.Info(R.string.feature_library_drop_no_link)
                },
            )
        }
    }

    private companion object {
        const val RECENT_TAGS = 20
        const val TOP_TAGS = 5
    }
}
