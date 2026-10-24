package app.sroka.feature.settings.impl.navigation

import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import app.sroka.feature.settings.api.ExportKey
import app.sroka.feature.settings.api.ImportKey
import app.sroka.feature.settings.api.SettingsKey
import app.sroka.feature.settings.impl.ExportRoute
import app.sroka.feature.settings.impl.ImportRoute
import app.sroka.feature.settings.impl.SettingsRoute

/**
 * Settings, import and export entries. Sign-out and account deletion change the session; the app
 * then navigates to sign-in on its own.
 *
 * @param onBack leave the current screen
 * @param onOpenImport push the import screen
 * @param onOpenExport push the export screen
 */
fun EntryProviderScope<NavKey>.settingsEntries(
    onBack: () -> Unit,
    onOpenImport: () -> Unit,
    onOpenExport: () -> Unit,
) {
    entry<SettingsKey> {
        SettingsRoute(onBack = onBack, onOpenImport = onOpenImport, onOpenExport = onOpenExport)
    }
    entry<ImportKey> { ImportRoute(onBack = onBack) }
    entry<ExportKey> { ExportRoute(onBack = onBack) }
}
