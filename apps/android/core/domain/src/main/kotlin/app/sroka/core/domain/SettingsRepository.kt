package app.sroka.core.domain

import app.sroka.core.model.DownloadPolicy
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.SortOrder
import app.sroka.core.model.ThemeMode
import app.sroka.core.model.UserPreferences
import kotlinx.coroutines.flow.Flow

/** Local preferences (DECISIONS A6). */
interface SettingsRepository {

    /** Current preferences; emits immediately (defaults when nothing is stored). */
    val preferences: Flow<UserPreferences>

    /** Server used when [UserPreferences.serverUrl] is null (build default). */
    val defaultServerUrl: String

    suspend fun setThemeMode(mode: ThemeMode)

    suspend fun setDynamicColor(enabled: Boolean)

    /** Changing the policy re-evaluates pending downloads. */
    suspend fun setDownloadPolicy(policy: DownloadPolicy)

    suspend fun setReaderTheme(theme: ReaderTheme)

    /** Clamped to [UserPreferences.READER_TEXT_SCALE_MIN]..[UserPreferences.READER_TEXT_SCALE_MAX]. */
    suspend fun setReaderTextScale(scale: Float)

    suspend fun setSortOrder(order: SortOrder)

    /** Custom server base URL; null restores [defaultServerUrl]. Invalid URLs return false. */
    suspend fun setServerUrl(url: String?): Boolean
}
