package app.sroka.core.datastore

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import app.sroka.core.model.DownloadPolicy
import app.sroka.core.model.ThemeMode
import app.sroka.core.model.UserPreferences
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class UserPreferencesDataSourceTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val scope = TestScope(UnconfinedTestDispatcher())
    private val dataStore = PreferenceDataStoreFactory.create(scope = scope.backgroundScope) {
        tmp.newFile("test.preferences_pb")
    }
    private val source = UserPreferencesDataSource(dataStore)

    @Test
    fun defaultsWhenEmpty() = scope.runTest {
        assertEquals(UserPreferences(), source.userPreferences.first())
    }

    @Test
    fun roundTripsAndClamps() = scope.runTest {
        source.setThemeMode(ThemeMode.DARK)
        source.setDownloadPolicy(DownloadPolicy.ANY_NETWORK)
        source.setReaderTextScale(5f)
        source.setServerUrl("https://example.com")
        val prefs = source.userPreferences.first()
        assertEquals(ThemeMode.DARK, prefs.themeMode)
        assertEquals(DownloadPolicy.ANY_NETWORK, prefs.downloadPolicy)
        assertEquals(UserPreferences.READER_TEXT_SCALE_MAX, prefs.readerTextScale)
        assertEquals("https://example.com", prefs.serverUrl)
        source.setServerUrl(null)
        assertEquals(null, source.userPreferences.first().serverUrl)
    }

    @Test
    fun unknownEnumFallsBackToDefault() = scope.runTest {
        dataStore.edit { it[stringPreferencesKey("theme_mode")] = "NEON" }
        assertEquals(ThemeMode.SYSTEM, source.userPreferences.first().themeMode)
    }
}
