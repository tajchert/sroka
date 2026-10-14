package app.sroka.feature.settings.impl.navigation

import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import app.sroka.feature.settings.api.SettingsKey
import app.sroka.feature.settings.impl.SettingsRoute

/**
 * Settings entry. Sign-out and account deletion change the session; the app then navigates to
 * sign-in on its own.
 *
 * @param onBack leave settings
 */
fun EntryProviderScope<NavKey>.settingsEntries(
    onBack: () -> Unit,
) {
    entry<SettingsKey> { SettingsRoute(onBack = onBack) }
}
