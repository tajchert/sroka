package app.sroka.core.testing.fake

import app.sroka.core.domain.SettingsRepository
import app.sroka.core.model.DownloadPolicy
import app.sroka.core.model.ReaderFont
import app.sroka.core.model.ReaderLineSpacing
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.SortOrder
import app.sroka.core.model.SwipeAction
import app.sroka.core.model.ThemeMode
import app.sroka.core.model.UrlNormalizer
import app.sroka.core.model.UserPreferences
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

/** In-memory [SettingsRepository]; [preferencesFlow] holds the current value. */
class FakeSettingsRepository(
    initial: UserPreferences = UserPreferences(),
    override val defaultServerUrl: String = "http://localhost:8787",
) : SettingsRepository {

    val preferencesFlow = MutableStateFlow(initial)

    override val preferences: Flow<UserPreferences> = preferencesFlow

    override suspend fun setThemeMode(mode: ThemeMode) = preferencesFlow.update { it.copy(themeMode = mode) }

    override suspend fun setDynamicColor(enabled: Boolean) = preferencesFlow.update { it.copy(dynamicColor = enabled) }

    override suspend fun setDownloadPolicy(policy: DownloadPolicy) = preferencesFlow.update { it.copy(downloadPolicy = policy) }

    override suspend fun setReaderTheme(theme: ReaderTheme) = preferencesFlow.update { it.copy(readerTheme = theme) }

    override suspend fun setReaderTextScale(scale: Float) = preferencesFlow.update {
        it.copy(readerTextScale = scale.coerceIn(UserPreferences.READER_TEXT_SCALE_MIN, UserPreferences.READER_TEXT_SCALE_MAX))
    }

    override suspend fun setReaderFont(font: ReaderFont) = preferencesFlow.update { it.copy(readerFont = font) }

    override suspend fun setReaderLineSpacing(spacing: ReaderLineSpacing) = preferencesFlow.update { it.copy(readerLineSpacing = spacing) }

    override suspend fun setSortOrder(order: SortOrder) = preferencesFlow.update { it.copy(sortOrder = order) }

    override suspend fun setSwipeLeftAction(action: SwipeAction) = preferencesFlow.update { it.copy(swipeLeftAction = action) }

    override suspend fun setSwipeRightAction(action: SwipeAction) = preferencesFlow.update { it.copy(swipeRightAction = action) }

    override suspend fun setSwipeHintShown() = preferencesFlow.update { it.copy(swipeHintShown = true) }

    override suspend fun setServerUrl(url: String?): Boolean {
        if (url != null && !UrlNormalizer.isHttpUrl(url)) return false
        preferencesFlow.update { it.copy(serverUrl = url) }
        return true
    }
}
