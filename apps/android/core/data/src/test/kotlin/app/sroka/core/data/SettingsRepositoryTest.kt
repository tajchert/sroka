package app.sroka.core.data

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import app.sroka.core.data.repository.SettingsRepositoryImpl
import app.sroka.core.data.sync.WorkScheduler
import app.sroka.core.datastore.UserPreferencesDataSource
import app.sroka.core.testing.fake.FakeAuthRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

internal class SettingsRepositoryTest : DataTestBase() {

    private val auth = FakeAuthRepository()

    private fun repo(): Pair<SettingsRepositoryImpl, UserPreferencesDataSource> {
        val store = PreferenceDataStoreFactory.create(scope = CoroutineScope(Dispatchers.IO + SupervisorJob())) {
            tmp.newFile("prefs-${System.nanoTime()}.preferences_pb")
        }
        val prefs = UserPreferencesDataSource(store)
        val context = androidx.test.core.app.ApplicationProvider.getApplicationContext<android.content.Context>()
        return SettingsRepositoryImpl(prefs, AppBuildInfo("https://api.sroka.app", "1"), WorkScheduler(context, prefs), sessionStore, auth) to prefs
    }

    @Test fun changingServerWhileSignedInSignsOutFirst() = runBlocking {
        val (settings, prefs) = repo()
        assertTrue(settings.setServerUrl("https://mirror.example"))
        assertEquals(1, auth.signOutCount)
        assertEquals("https://mirror.example", prefs.userPreferences.first().serverUrl)
    }

    @Test fun sameServerOrSignedOutDoesNotSignOut() = runBlocking {
        val (settings, _) = repo()
        assertTrue(settings.setServerUrl("https://api.sroka.app/")) // the default, spelled differently
        assertTrue(settings.setServerUrl(null))
        assertEquals(0, auth.signOutCount)
        assertFalse(settings.setServerUrl("not a url"))
        sessionStore.clear()
        assertTrue(settings.setServerUrl("https://mirror.example"))
        assertEquals(0, auth.signOutCount)
    }
}
