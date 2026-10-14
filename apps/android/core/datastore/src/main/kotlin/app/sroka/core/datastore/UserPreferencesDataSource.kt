package app.sroka.core.datastore

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import app.sroka.core.model.DownloadPolicy
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.SortOrder
import app.sroka.core.model.ThemeMode
import app.sroka.core.model.UserPreferences
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import java.io.IOException
import javax.inject.Inject

/**
 * [UserPreferences] (DECISIONS A6) backed by Preferences DataStore. Enum values are stored by name
 * and decoded defensively, so an unknown value (rename, downgrade) falls back to the default instead
 * of failing the whole stream.
 */
class UserPreferencesDataSource @Inject constructor(
    private val dataStore: DataStore<Preferences>,
) {
    val userPreferences: Flow<UserPreferences> = dataStore.data
        .catch { throwable ->
            if (throwable is IOException) emit(emptyPreferences()) else throw throwable
        }
        .map { p ->
            val defaults = UserPreferences()
            UserPreferences(
                themeMode = p[THEME_MODE]?.let { enumValueOrNull<ThemeMode>(it) } ?: defaults.themeMode,
                dynamicColor = p[DYNAMIC_COLOR] ?: defaults.dynamicColor,
                downloadPolicy = p[DOWNLOAD_POLICY]?.let { enumValueOrNull<DownloadPolicy>(it) } ?: defaults.downloadPolicy,
                readerTheme = p[READER_THEME]?.let { enumValueOrNull<ReaderTheme>(it) } ?: defaults.readerTheme,
                readerTextScale = (p[READER_TEXT_SCALE] ?: defaults.readerTextScale).coerceIn(
                    UserPreferences.READER_TEXT_SCALE_MIN,
                    UserPreferences.READER_TEXT_SCALE_MAX,
                ),
                sortOrder = p[SORT_ORDER]?.let { enumValueOrNull<SortOrder>(it) } ?: defaults.sortOrder,
                serverUrl = p[SERVER_URL],
            )
        }

    suspend fun setThemeMode(value: ThemeMode) = dataStore.edit { it[THEME_MODE] = value.name }

    suspend fun setDynamicColor(value: Boolean) = dataStore.edit { it[DYNAMIC_COLOR] = value }

    suspend fun setDownloadPolicy(value: DownloadPolicy) = dataStore.edit { it[DOWNLOAD_POLICY] = value.name }

    suspend fun setReaderTheme(value: ReaderTheme) = dataStore.edit { it[READER_THEME] = value.name }

    suspend fun setReaderTextScale(value: Float) = dataStore.edit {
        it[READER_TEXT_SCALE] = value.coerceIn(UserPreferences.READER_TEXT_SCALE_MIN, UserPreferences.READER_TEXT_SCALE_MAX)
    }

    suspend fun setSortOrder(value: SortOrder) = dataStore.edit { it[SORT_ORDER] = value.name }

    /** null clears the override (build default server). */
    suspend fun setServerUrl(value: String?) = dataStore.edit {
        if (value == null) it.remove(SERVER_URL) else it[SERVER_URL] = value
    }

    private companion object {
        val THEME_MODE = stringPreferencesKey("theme_mode")
        val DYNAMIC_COLOR = booleanPreferencesKey("dynamic_color")
        val DOWNLOAD_POLICY = stringPreferencesKey("download_policy")
        val READER_THEME = stringPreferencesKey("reader_theme")
        val READER_TEXT_SCALE = floatPreferencesKey("reader_text_scale")
        val SORT_ORDER = stringPreferencesKey("sort_order")
        val SERVER_URL = stringPreferencesKey("server_url")
    }
}

/** Reads persisted enum names defensively. */
private inline fun <reified T : Enum<T>> enumValueOrNull(value: String): T? =
    enumValues<T>().firstOrNull { it.name == value }
