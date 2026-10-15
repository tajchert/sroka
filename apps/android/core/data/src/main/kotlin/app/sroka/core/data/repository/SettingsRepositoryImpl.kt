package app.sroka.core.data.repository

import app.sroka.core.data.AppBuildInfo
import app.sroka.core.data.sync.WorkScheduler
import app.sroka.core.datastore.SessionStore
import app.sroka.core.datastore.UserPreferencesDataSource
import app.sroka.core.domain.AuthRepository
import app.sroka.core.domain.SettingsRepository
import app.sroka.core.model.DownloadPolicy
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.SortOrder
import app.sroka.core.model.ThemeMode
import app.sroka.core.model.UserPreferences
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
internal class SettingsRepositoryImpl @Inject constructor(
    private val dataSource: UserPreferencesDataSource,
    private val buildInfo: AppBuildInfo,
    private val scheduler: WorkScheduler,
    private val sessionStore: SessionStore,
    private val auth: AuthRepository,
) : SettingsRepository {

    override val preferences: Flow<UserPreferences> = dataSource.userPreferences

    override val defaultServerUrl: String get() = buildInfo.defaultServerUrl

    override suspend fun setThemeMode(mode: ThemeMode) {
        dataSource.setThemeMode(mode)
    }

    override suspend fun setDynamicColor(enabled: Boolean) {
        dataSource.setDynamicColor(enabled)
    }

    override suspend fun setDownloadPolicy(policy: DownloadPolicy) {
        dataSource.setDownloadPolicy(policy)
        scheduler.onDownloadPolicyChanged(policy)
    }

    override suspend fun setReaderTheme(theme: ReaderTheme) {
        dataSource.setReaderTheme(theme)
    }

    override suspend fun setReaderTextScale(scale: Float) {
        dataSource.setReaderTextScale(scale.coerceIn(UserPreferences.READER_TEXT_SCALE_MIN, UserPreferences.READER_TEXT_SCALE_MAX))
    }

    override suspend fun setSortOrder(order: SortOrder) {
        dataSource.setSortOrder(order)
    }

    override suspend fun setServerUrl(url: String?): Boolean {
        val normalized = if (url.isNullOrBlank()) null else normalizeServerUrl(url) ?: return false
        val stored = normalized?.takeUnless { it == buildInfo.defaultServerUrl.trimEnd('/') }
        if (stored != dataSource.userPreferences.first().serverUrl && sessionStore.current() != null) {
            // The bearer token, library, cursor and queued ops belong to the old server: never send
            // them to the new host. Sign out first (revokes the token against the old base URL and
            // wipes local data), then switch.
            auth.signOut()
        }
        dataSource.setServerUrl(stored)
        return true
    }
}

/** `http(s)://host[:port][/path]` without query/fragment, no trailing slash; null if invalid. */
internal fun normalizeServerUrl(input: String): String? {
    val url = input.trim().toHttpUrlOrNull() ?: return null
    if (url.host.isEmpty() || url.query != null || url.fragment != null || url.username.isNotEmpty()) return null
    return url.toString().trimEnd('/')
}
