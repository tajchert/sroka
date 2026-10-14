package app.sroka.feature.settings.impl.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import app.sroka.feature.settings.api.SettingsKey
import app.sroka.feature.settings.impl.R

/**
 * Settings entry. Sign-out and account deletion change the session; the app then navigates to
 * sign-in on its own.
 *
 * @param onBack leave settings
 */
fun EntryProviderScope<NavKey>.settingsEntries(
    onBack: () -> Unit,
) {
    entry<SettingsKey> {
        // Placeholder until the settings feature is implemented.
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.feature_settings_title))
        }
    }
}
