package app.sroka.feature.settings.impl

import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.tooling.preview.Preview
import app.sroka.core.designsystem.theme.SrokaTheme
import com.android.tools.screenshot.PreviewTest

// Google Play screenshot. Rendered on a tall 360x1330dp canvas (the real screen scrolls); the store script crops
// the Privacy / Account part out of it to 1080x1920.
@PreviewTest
@Preview(name = "StorePhoneSettingsTall", showBackground = true, device = "spec:width=360dp,height=1330dp,dpi=480", apiLevel = 36)
@Composable
fun StorePhoneSettingsTall() {
    SrokaTheme(darkTheme = false) {
        SettingsScreen(
            state = SettingsUiState(
                email = "magpie@example.com",
                storageBytes = 48_000_000,
                serverUrl = "https://api.sroka.app",
                telemetryAvailable = true,
            ),
            vm = SettingsActions(),
            snackbar = remember { SnackbarHostState() },
            onBack = {},
            onOpenImport = {},
            onOpenExport = {},
        )
    }
}
