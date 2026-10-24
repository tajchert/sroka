package app.sroka.feature.settings.impl

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.component.DetailPaneCard
import app.sroka.feature.settings.api.SettingsChoiceKind
import app.sroka.core.designsystem.preview.FoldablePreviews
import app.sroka.core.designsystem.theme.SrokaTheme
import com.android.tools.screenshot.PreviewTest

@PreviewTest
@FoldablePreviews
@Composable
fun SettingsPopulated() {
    SrokaTheme(darkTheme = false) {
        SettingsScreen(
            state = SettingsUiState(
                email = "magpie@example.com",
                storageBytes = 48_000_000,
                serverUrl = "https://api.sroka.app",
            ),
            vm = SettingsActions(),
            snackbar = remember { SnackbarHostState() },
            onBack = {},
            onOpenImport = {},
            onOpenExport = {},
        )
    }
}

@PreviewTest
@FoldablePreviews
@Composable
fun ImportFilePicked() {
    SrokaTheme(darkTheme = false) {
        ImportScreen(
            state = ImportUiState(fileName = "ril_export.html", fileSizeBytes = 482_000),
            onBack = {},
            onSource = {},
            onPicked = {},
            onImport = {},
            onDone = {},
        )
    }
}

@PreviewTest
@FoldablePreviews
@Composable
fun ExportReady() {
    SrokaTheme(darkTheme = false) {
        ExportScreen(
            state = ExportUiState(ready = ReadyExport(path = "/data/exports/sroka-export.json", fileName = "sroka-export.json", bytes = 128_000)),
            onBack = {},
            onFormat = {},
            onExport = {},
        )
    }
}

@Composable
private fun SettingsTwoPane(selected: SettingsSelection?, detail: @Composable () -> Unit) {
    SrokaTheme(darkTheme = false) {
        Surface(color = MaterialTheme.colorScheme.background) {
            Row(Modifier.fillMaxSize()) {
                Box(Modifier.width(360.dp)) {
                    SettingsScreen(
                        state = SettingsUiState(
                            email = "magpie@example.com",
                            storageBytes = 48_000_000,
                            serverUrl = "https://api.sroka.app",
                        ),
                        vm = SettingsActions(),
                        snackbar = remember { SnackbarHostState() },
                        onBack = {},
                        onOpenImport = {},
                        onOpenExport = {},
                        twoPane = true,
                        selected = selected,
                    )
                }
                Spacer(Modifier.width(24.dp))
                Box(Modifier.weight(1f)) { DetailPaneCard(topMargin = 0.dp) { detail() } }
            }
        }
    }
}

@PreviewTest
@FoldablePreviews
@Composable
fun SettingsTwoPanePlaceholder() = SettingsTwoPane(null) { SettingsDetailPlaceholder() }

@PreviewTest
@FoldablePreviews
@Composable
fun SettingsTwoPaneTheme() = SettingsTwoPane(SettingsSelection.Theme) {
    SettingsChoiceScreen(
        SettingsChoiceKind.Theme,
        SettingsUiState(serverUrl = "https://api.sroka.app"),
        SettingsActions(),
        remember { SnackbarHostState() },
    )
}

@PreviewTest
@FoldablePreviews
@Composable
fun SettingsTwoPaneImport() = SettingsTwoPane(SettingsSelection.Import) {
    ImportScreen(
        state = ImportUiState(fileName = "ril_export.html", fileSizeBytes = 482_000),
        onBack = {},
        onSource = {},
        onPicked = {},
        onImport = {},
        onDone = {},
        detailPane = true,
    )
}
