package app.sroka.feature.settings.impl.navigation

import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.navigation3.ListDetailSceneStrategy
import androidx.compose.ui.unit.dp
import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import app.sroka.core.designsystem.component.DetailPaneCard
import app.sroka.core.ui.adaptive.LocalPaneLayout
import app.sroka.feature.settings.api.ExportKey
import app.sroka.feature.settings.api.ImportKey
import app.sroka.feature.settings.api.SettingsChoiceKey
import app.sroka.feature.settings.api.SettingsChoiceKind
import app.sroka.feature.settings.api.SettingsKey
import app.sroka.feature.settings.impl.ExportRoute
import app.sroka.feature.settings.impl.ImportRoute
import app.sroka.feature.settings.impl.SettingsChoiceRoute
import app.sroka.feature.settings.impl.SettingsDetailPlaceholder
import app.sroka.feature.settings.impl.SettingsRoute
import app.sroka.feature.settings.impl.SettingsSelection

/**
 * Own scene key: Settings pairs only with its own detail pages, never with a reader left on the
 * stack below it (ListDetailSceneStrategy otherwise combines the newest list and detail entries).
 */
private const val SettingsSceneKey = "sroka.settings"

/**
 * Settings, import and export entries. Sign-out and account deletion change the session; the app
 * then navigates to sign-in on its own.
 *
 * On two-pane windows settings is the list pane and import, export and the choice pages
 * ([SettingsChoiceKey]) are detail panes in a [DetailPaneCard] without a back arrow (R14.4).
 *
 * @param onBack leave the current screen
 * @param onOpenImport open the import screen
 * @param onOpenExport open the export screen
 * @param onOpenChoice open a choice page in the detail pane (two-pane only)
 * @param topKey the key on top of the back stack (read lazily; highlights the open row)
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
fun EntryProviderScope<NavKey>.settingsEntries(
    onBack: () -> Unit,
    onOpenImport: () -> Unit,
    onOpenExport: () -> Unit,
    onOpenChoice: (SettingsChoiceKind) -> Unit = {},
    topKey: () -> NavKey? = { null },
) {
    entry<SettingsKey>(
        metadata = ListDetailSceneStrategy.listPane(
            sceneKey = SettingsSceneKey,
            detailPlaceholder = { DetailPaneCard(topMargin = 0.dp) { SettingsDetailPlaceholder() } },
        ) + ListDetailSceneStrategy.preferredPaneSize(width = 360.dp),
    ) {
        val twoPane = LocalPaneLayout.current.twoPane
        SettingsRoute(
            onBack = onBack,
            onOpenImport = onOpenImport,
            onOpenExport = onOpenExport,
            twoPane = twoPane,
            selected = if (twoPane) selectionOf(topKey()) else null,
            onOpenChoice = onOpenChoice,
        )
    }
    entry<SettingsChoiceKey>(metadata = ListDetailSceneStrategy.detailPane(sceneKey = SettingsSceneKey)) { key ->
        DetailPaneCard(topMargin = 0.dp) { SettingsChoiceRoute(key.kind) }
    }
    entry<ImportKey>(metadata = ListDetailSceneStrategy.detailPane(sceneKey = SettingsSceneKey)) {
        val twoPane = LocalPaneLayout.current.twoPane
        if (twoPane) DetailPaneCard(topMargin = 0.dp) { ImportRoute(onBack = onBack, detailPane = true) } else ImportRoute(onBack = onBack)
    }
    entry<ExportKey>(metadata = ListDetailSceneStrategy.detailPane(sceneKey = SettingsSceneKey)) {
        val twoPane = LocalPaneLayout.current.twoPane
        if (twoPane) DetailPaneCard(topMargin = 0.dp) { ExportRoute(onBack = onBack, detailPane = true) } else ExportRoute(onBack = onBack)
    }
}

private fun selectionOf(key: NavKey?): SettingsSelection? = when (key) {
    is SettingsChoiceKey -> when (key.kind) {
        SettingsChoiceKind.Theme -> SettingsSelection.Theme
        SettingsChoiceKind.ReaderTheme -> SettingsSelection.ReaderTheme
        SettingsChoiceKind.TextSize -> SettingsSelection.TextSize
        SettingsChoiceKind.Offline -> SettingsSelection.Offline
        SettingsChoiceKind.Server -> SettingsSelection.Server
    }
    ImportKey -> SettingsSelection.Import
    ExportKey -> SettingsSelection.Export
    else -> null
}
