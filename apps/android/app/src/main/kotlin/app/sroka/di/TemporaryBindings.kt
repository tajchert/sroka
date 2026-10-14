package app.sroka.di

import android.content.Context
import androidx.paging.PagingData
import app.sroka.BuildConfig
import app.sroka.core.domain.AccountRepository
import app.sroka.core.domain.AuthRepository
import app.sroka.core.domain.AuthResult
import app.sroka.core.domain.ContentStore
import app.sroka.core.domain.DeleteAccountResult
import app.sroka.core.domain.DownloadResult
import app.sroka.core.domain.LibraryRepository
import app.sroka.core.domain.RemoteFailure
import app.sroka.core.domain.SaveSource
import app.sroka.core.domain.SettingsRepository
import app.sroka.core.domain.SyncController
import app.sroka.core.domain.SyncEvent
import app.sroka.core.domain.SyncStatusRepository
import app.sroka.core.domain.TagEditResult
import app.sroka.core.domain.TagRepository
import app.sroka.core.model.DownloadPolicy
import app.sroka.core.model.Item
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.LibraryCounts
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.SaveResult
import app.sroka.core.model.SessionState
import app.sroka.core.model.SortOrder
import app.sroka.core.model.SyncStatus
import app.sroka.core.model.TagCount
import app.sroka.core.model.ThemeMode
import app.sroka.core.model.UrlNormalizer
import app.sroka.core.model.UserPreferences
import app.sroka.core.model.newUuidV7
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.update
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

// =============================================================================
// TEMPORARY BINDINGS - DELETE AT INTEGRATION
// =============================================================================
// Minimal in-memory implementations of the core:domain interfaces so the app
// compiles and runs while core:data is built in parallel. The integration step
// deletes this file and adds `implementation(projects.core.data)` to :app.
// =============================================================================

@Module
@InstallIn(SingletonComponent::class)
internal abstract class TemporaryBindings {
    @Binds @Singleton abstract fun library(impl: TemporaryLibraryRepository): LibraryRepository
    @Binds @Singleton abstract fun tags(impl: TemporaryTagRepository): TagRepository
    @Binds @Singleton abstract fun syncController(impl: TemporarySyncController): SyncController
    @Binds @Singleton abstract fun syncStatus(impl: TemporarySyncStatusRepository): SyncStatusRepository
    @Binds @Singleton abstract fun content(impl: TemporaryContentStore): ContentStore
    @Binds @Singleton abstract fun auth(impl: TemporaryAuthRepository): AuthRepository
    @Binds @Singleton abstract fun settings(impl: TemporarySettingsRepository): SettingsRepository
    @Binds @Singleton abstract fun account(impl: TemporaryAccountRepository): AccountRepository
}

internal class TemporaryLibraryRepository @Inject constructor() : LibraryRepository {
    override fun pagedItems(query: ItemQuery): Flow<PagingData<ItemSummary>> = flowOf(PagingData.empty())
    override fun observeItem(id: String): Flow<Item?> = flowOf(null)
    override fun observeCounts(): Flow<LibraryCounts> = flowOf(LibraryCounts())
    override suspend fun save(url: String, title: String?, tags: List<String>, source: SaveSource): SaveResult =
        if (UrlNormalizer.normalize(url) == null) SaveResult.InvalidUrl else SaveResult.Saved(newUuidV7(), alreadySaved = false)
    override suspend fun setStatus(id: String, status: ItemStatus) = Unit
    override suspend fun setFavorite(id: String, favorite: Boolean) = Unit
    override suspend fun setProgress(id: String, progress: Float, anchor: Int?) = Unit
    override suspend fun setTitle(id: String, title: String?) = Unit
    override suspend fun setTags(id: String, names: List<String>) = Unit
    override suspend fun delete(id: String) = Unit
    override suspend fun refresh(id: String) = Unit
}

internal class TemporaryTagRepository @Inject constructor() : TagRepository {
    override fun observeTags(): Flow<List<TagCount>> = flowOf(emptyList())
    override fun observeRecentTags(limit: Int): Flow<List<String>> = flowOf(emptyList())
    override suspend fun rename(from: String, to: String): TagEditResult = TagEditResult.Done
    override suspend fun delete(name: String) = Unit
}

internal class TemporarySyncController @Inject constructor() : SyncController {
    override fun requestSync() = Unit
    override fun fetchNewArticles() = Unit
    override fun downloadItemNow(itemId: String) = Unit
}

internal class TemporarySyncStatusRepository @Inject constructor() : SyncStatusRepository {
    override val status: Flow<SyncStatus> = flowOf(SyncStatus())
    override val events: Flow<SyncEvent> = emptyFlow()
}

internal class TemporaryContentStore @Inject constructor(
    @param:ApplicationContext private val context: Context,
) : ContentStore {
    override fun observeOffline(itemId: String): Flow<OfflineState> = flowOf(OfflineState.NONE)
    override suspend fun articleHtml(itemId: String): String? = null
    override fun articlesDirectory(): File = File(context.filesDir, "articles")
    override suspend fun downloadNow(itemId: String): DownloadResult = DownloadResult.Failed(RemoteFailure.NETWORK)
    override suspend fun storageUsageBytes(): Long = 0
    override suspend fun clearDownloads() = Unit
}

/** Accepts any email/code so the signed-in shell can be exercised before the real auth exists. */
@Singleton
internal class TemporaryAuthRepository @Inject constructor() : AuthRepository {
    private val state = MutableStateFlow<SessionState>(SessionState.SignedOut)
    override val session: Flow<SessionState> = state
    override suspend fun sendCode(email: String): AuthResult = AuthResult.Success
    override suspend fun signIn(email: String, code: String): AuthResult {
        state.value = SessionState.SignedIn(email)
        return AuthResult.Success
    }
    override suspend fun signOut() {
        state.value = SessionState.SignedOut
    }
}

@Singleton
internal class TemporarySettingsRepository @Inject constructor() : SettingsRepository {
    private val state = MutableStateFlow(UserPreferences())
    override val preferences: Flow<UserPreferences> = state
    override val defaultServerUrl: String = BuildConfig.DEFAULT_SERVER_URL
    override suspend fun setThemeMode(mode: ThemeMode) = state.update { it.copy(themeMode = mode) }
    override suspend fun setDynamicColor(enabled: Boolean) = state.update { it.copy(dynamicColor = enabled) }
    override suspend fun setDownloadPolicy(policy: DownloadPolicy) = state.update { it.copy(downloadPolicy = policy) }
    override suspend fun setReaderTheme(theme: ReaderTheme) = state.update { it.copy(readerTheme = theme) }
    override suspend fun setReaderTextScale(scale: Float) = state.update {
        it.copy(readerTextScale = scale.coerceIn(UserPreferences.READER_TEXT_SCALE_MIN, UserPreferences.READER_TEXT_SCALE_MAX))
    }
    override suspend fun setSortOrder(order: SortOrder) = state.update { it.copy(sortOrder = order) }
    override suspend fun setServerUrl(url: String?): Boolean {
        if (url != null && !UrlNormalizer.isHttpUrl(url)) return false
        state.update { it.copy(serverUrl = url) }
        return true
    }
}

internal class TemporaryAccountRepository @Inject constructor() : AccountRepository {
    override suspend fun deleteAccount(): DeleteAccountResult = DeleteAccountResult.Failed(RemoteFailure.SERVER)
}
