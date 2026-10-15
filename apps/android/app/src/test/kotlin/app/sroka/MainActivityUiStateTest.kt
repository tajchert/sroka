package app.sroka

import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SessionState
import app.sroka.core.model.ThemeMode
import app.sroka.core.model.UserPreferences
import app.sroka.feature.library.api.LibraryKey
import app.sroka.feature.reader.api.ReaderKey
import app.sroka.navigation.TopLevelDestination
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MainActivityUiStateTest {

    @Test
    fun expiredSessionCountsAsSignedIn() {
        assertTrue(success(SessionState.Expired("a@b.c")).isSignedIn)
        assertTrue(success(SessionState.SignedIn("a@b.c")).isSignedIn)
        assertFalse(success(SessionState.SignedOut).isSignedIn)
    }

    @Test
    fun themeModeDecidesDarkTheme() {
        assertTrue(MainActivityUiState.Loading.shouldUseDarkTheme(isSystemInDarkTheme = true))
        assertFalse(success(prefs = UserPreferences(themeMode = ThemeMode.LIGHT)).shouldUseDarkTheme(true))
        assertTrue(success(prefs = UserPreferences(themeMode = ThemeMode.DARK)).shouldUseDarkTheme(false))
        assertFalse(MainActivityUiState.Loading.shouldUseDynamicColor())
    }

    @Test
    fun topLevelDestinationMatchesTabRootsOnly() {
        assertEquals(TopLevelDestination.ARCHIVE, TopLevelDestination.of(LibraryKey(LibraryTab.ARCHIVE)))
        assertNull(TopLevelDestination.of(ReaderKey("x")))
    }

    private fun success(
        session: SessionState = SessionState.SignedOut,
        prefs: UserPreferences = UserPreferences(),
    ) = MainActivityUiState.Success(prefs, session)
}
