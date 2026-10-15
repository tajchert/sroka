package app.sroka.feature.reader.impl

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.sroka.core.common.di.ApplicationScope
import app.sroka.core.domain.ContentStore
import app.sroka.core.domain.DownloadResult
import app.sroka.core.domain.LibraryRepository
import app.sroka.core.domain.RemoteFailure
import app.sroka.core.domain.SettingsRepository
import app.sroka.core.domain.TagRepository
import app.sroka.core.model.Item
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.UserPreferences
import dagger.assisted.Assisted
import dagger.assisted.AssistedFactory
import dagger.assisted.AssistedInject
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

sealed interface ReaderUiState {
    data object Loading : ReaderUiState

    /** [html] is the raw downloaded article.html; the screen wraps it with theme + restore point. */
    data class Ready(val html: String, val baseUrl: String) : ReaderUiState

    /** Fetching the article package now. */
    data object Downloading : ReaderUiState

    data class NotDownloaded(val reason: NotDownloadedReason) : ReaderUiState

    /** The server has not finished parsing. */
    data object ParsePending : ReaderUiState

    data class ParseFailed(val error: String?) : ReaderUiState

    /** The item no longer exists (deleted here or by sync). */
    data object Missing : ReaderUiState
}

enum class NotDownloadedReason { OFFLINE, SIGN_IN, ERROR }

/** Where to scroll when the article is shown. */
data class RestorePoint(val anchor: Int?, val progress: Float)

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel(assistedFactory = ReaderViewModel.Factory::class)
class ReaderViewModel @AssistedInject constructor(
    @Assisted private val itemId: String,
    private val library: LibraryRepository,
    private val content: ContentStore,
    private val settings: SettingsRepository,
    tagRepository: TagRepository,
    @ApplicationScope private val appScope: CoroutineScope,
) : ViewModel() {

    @AssistedFactory
    interface Factory {
        fun create(itemId: String): ReaderViewModel
    }

    /** Test seam. */
    internal var nowMillis: () -> Long = System::currentTimeMillis

    private data class SourceKey(
        val missing: Boolean,
        val parse: ParseStatus,
        val hasContent: Boolean,
        val offline: OfflineState,
    )

    private val retry = MutableStateFlow(0)

    /** Result of the VM-initiated download; lives outside the key-driven flow so it is never cancelled by it. */
    private val vmDownload = MutableStateFlow<ReaderUiState?>(null)
    private var autoDownloadedAttempt = -1
    private var latestItem: Item? = null
    private var reported: ProgressReport? = null
    private var lastSavedAt: Long? = null
    private var unsaved = false
    private var ready = false

    val item: StateFlow<Item?> = library.observeItem(itemId)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(STOP_TIMEOUT_MS), null)

    val preferences: StateFlow<UserPreferences> = settings.preferences
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(STOP_TIMEOUT_MS), UserPreferences())

    val recentTags: StateFlow<List<String>> = tagRepository.observeRecentTags(RECENT_TAGS)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(STOP_TIMEOUT_MS), emptyList())

    /** Live reading progress for the indicator (0..1). */
    private val _progress = MutableStateFlow(0f)
    val progress: StateFlow<Float> = _progress

    val uiState: StateFlow<ReaderUiState> = combine(
        library.observeItem(itemId),
        content.observeOffline(itemId),
    ) { item, offline ->
        latestItem = item
        if (item == null) {
            SourceKey(true, ParseStatus.PENDING, false, offline)
        } else {
            SourceKey(false, item.parseStatus, item.contentId != null, offline)
        }
    }
        .distinctUntilChanged()
        .combine(retry) { key, attempt -> key to attempt }
        .flatMapLatest { (key, attempt) -> resolve(key, attempt) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(STOP_TIMEOUT_MS), ReaderUiState.Loading)

    private fun resolve(key: SourceKey, attempt: Int): Flow<ReaderUiState> = flow {
        ready = false
        when {
            key.missing -> emit(ReaderUiState.Missing)
            key.offline == OfflineState.DOWNLOADED -> {
                val html = content.articleHtml(itemId)
                if (html != null) emitReady(html) else emitAll(download(key, attempt))
            }
            !key.hasContent -> emit(
                if (key.parse == ParseStatus.FAILED) {
                    ReaderUiState.ParseFailed(latestItem?.parseError)
                } else {
                    ReaderUiState.ParsePending
                },
            )
            // Already in flight; the offline flow moves us on when it finishes.
            key.offline == OfflineState.DOWNLOADING -> emit(ReaderUiState.Downloading)
            else -> emitAll(download(key, attempt))
        }
    }

    private suspend fun kotlinx.coroutines.flow.FlowCollector<ReaderUiState>.emitReady(html: String) {
        ready = true
        // Start from the saved position; restorePoint() refines it for recreated WebViews.
        reported = null
        emit(ReaderUiState.Ready(html, content.articleBaseUrl(itemId)))
    }

    /** Downloads at most once per retry [attempt]; later keys of the same attempt show the outcome. */
    private fun download(key: SourceKey, attempt: Int): Flow<ReaderUiState> = flow {
        if (attempt != autoDownloadedAttempt) {
            autoDownloadedAttempt = attempt
            vmDownload.value = ReaderUiState.Downloading
            viewModelScope.launch { vmDownload.value = mapResult(content.downloadNow(itemId)) }
        } else if (vmDownload.value == null) {
            emit(
                ReaderUiState.NotDownloaded(
                    if (key.offline == OfflineState.FAILED) NotDownloadedReason.ERROR else NotDownloadedReason.OFFLINE,
                ),
            )
            return@flow
        }
        emitAll(vmDownload.filterNotNull().onEach { if (it is ReaderUiState.Ready) ready = true })
    }

    private suspend fun mapResult(result: DownloadResult): ReaderUiState = when (result) {
        DownloadResult.Downloaded -> {
            val html = content.articleHtml(itemId)
            if (html != null) {
                ready = true
                reported = null
                ReaderUiState.Ready(html, content.articleBaseUrl(itemId))
            } else {
                ReaderUiState.NotDownloaded(NotDownloadedReason.ERROR)
            }
        }
        DownloadResult.NotReady -> ReaderUiState.ParsePending
        is DownloadResult.Failed -> ReaderUiState.NotDownloaded(
            when (result.reason) {
                RemoteFailure.NETWORK -> NotDownloadedReason.OFFLINE
                RemoteFailure.UNAUTHORIZED -> NotDownloadedReason.SIGN_IN
                else -> NotDownloadedReason.ERROR
            },
        )
    }

    /** Try the download again (not-downloaded screen). */
    fun retryDownload() = retry.update { it + 1 }

    /** Where the article should open: the latest reported position, else the saved one. */
    fun restorePoint(): RestorePoint {
        reported?.let { return RestorePoint(it.anchor, it.progress) }
        val saved = latestItem
        return RestorePoint(saved?.progressAnchor, saved?.progress ?: 0f)
    }

    /** Called by the reader script (debounced in JS); persists at most every [SAVE_INTERVAL_MS]. */
    fun onProgress(report: ProgressReport) {
        if (!ready) return
        reported = report
        _progress.value = report.progress
        unsaved = true
        val now = nowMillis()
        if (lastSavedAt.let { it == null || now - it >= SAVE_INTERVAL_MS }) {
            lastSavedAt = now
            unsaved = false
            viewModelScope.launch { library.setProgress(itemId, report.progress, report.anchor) }
        }
    }

    /** Persist the latest position (and bump lastRead) when leaving or stopping. */
    fun flushProgress() {
        if (!ready) return
        val report = reported ?: latestItem?.let { ProgressReport(it.progress, it.progressAnchor) } ?: return
        if (reported != null && !unsaved) return
        unsaved = false
        lastSavedAt = nowMillis()
        // App scope: the write must survive this ViewModel being cleared (back, two-pane replacement).
        appScope.launch { library.setProgress(itemId, report.progress, report.anchor) }
    }

    /** Public so tests can simulate the ViewModelStore clearing this entry. */
    public override fun onCleared() {
        flushProgress()
    }

    fun toggleFavorite() {
        val current = item.value ?: return
        viewModelScope.launch { library.setFavorite(itemId, !current.isFavorite) }
    }

    /** Archives, or moves back to My List when already archived. [onDone] gets true when archived. */
    fun toggleArchive(onDone: (archived: Boolean) -> Unit) {
        val current = item.value ?: return
        val archive = current.status != ItemStatus.ARCHIVED
        viewModelScope.launch {
            library.setStatus(itemId, if (archive) ItemStatus.ARCHIVED else ItemStatus.UNREAD)
            onDone(archive)
        }
    }

    fun setTags(names: List<String>) {
        viewModelScope.launch { library.setTags(itemId, names) }
    }

    fun refresh() {
        viewModelScope.launch { library.refresh(itemId) }
    }

    fun delete() {
        ready = false // do not write progress for a deleted item
        viewModelScope.launch { library.delete(itemId) }
    }

    fun setReaderTheme(theme: ReaderTheme) {
        viewModelScope.launch { settings.setReaderTheme(theme) }
    }

    fun setTextScale(scale: Float) {
        viewModelScope.launch { settings.setReaderTextScale(scale) }
    }

    private companion object {
        const val STOP_TIMEOUT_MS = 5_000L
        const val SAVE_INTERVAL_MS = 2_000L
        const val RECENT_TAGS = 8
    }
}
