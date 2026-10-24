package app.sroka.feature.auth.impl

import androidx.compose.runtime.Composable
import app.sroka.core.designsystem.preview.FoldablePreviews
import app.sroka.core.designsystem.theme.SrokaTheme
import com.android.tools.screenshot.PreviewTest

@PreviewTest
@FoldablePreviews
@Composable
fun SignInEmailStep() {
    SrokaTheme(darkTheme = false) {
        AuthScreen(
            state = AuthUiState(email = "magpie@example.com", serverUrl = "https://api.sroka.app"),
            onEmailChange = {},
            onSendCode = {},
            onCodeChange = {},
            onResend = {},
            onChangeEmail = {},
            onOpenServer = {},
            onDismissServer = {},
            onSaveServer = {},
        )
    }
}
