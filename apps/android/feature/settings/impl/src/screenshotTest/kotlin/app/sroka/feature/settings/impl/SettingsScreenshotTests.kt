package app.sroka.feature.settings.impl

import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
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
