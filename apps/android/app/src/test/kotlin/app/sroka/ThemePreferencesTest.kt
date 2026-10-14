package app.sroka

import app.sroka.core.model.ThemeBrand
import app.sroka.core.model.UserPreferences
import org.junit.Assert.*
import org.junit.Test

class ThemePreferencesTest {
    @Test fun `default brand uses app palette and dynamic brand uses wallpaper palette`() {
        assertFalse(MainActivityUiState.Loading.shouldUseDynamicColor())
        assertFalse(MainActivityUiState.Success(UserPreferences()).shouldUseDynamicColor())
        assertTrue(MainActivityUiState.Success(UserPreferences(themeBrand = ThemeBrand.DYNAMIC)).shouldUseDynamicColor())
    }
}
