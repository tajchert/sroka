package app.sroka.core.domain

import app.sroka.core.model.DownloadPolicy
import app.sroka.core.model.ReaderFont
import app.sroka.core.model.ReaderLineSpacing
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.SortOrder
import app.sroka.core.model.SwipeAction
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

    suspend fun setReaderFont(font: ReaderFont)

    suspend fun setReaderLineSpacing(spacing: ReaderLineSpacing)

    suspend fun setSortOrder(order: SortOrder)

    /** Action of a row swipe towards the left edge. */
    suspend fun setSwipeLeftAction(action: SwipeAction)

    /** Action of a row swipe towards the right edge. */
    suspend fun setSwipeRightAction(action: SwipeAction)

    /** Records that the one-time swipe hint has played, so it never plays again. */
    suspend fun setSwipeHintShown()

    /** Custom server base URL; null restores [defaultServerUrl]. Invalid URLs return false. */
    suspend fun setServerUrl(url: String?): Boolean
}
