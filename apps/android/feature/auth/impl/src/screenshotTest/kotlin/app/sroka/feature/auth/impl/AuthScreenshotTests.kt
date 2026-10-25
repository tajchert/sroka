package app.sroka.feature.auth.impl

import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview
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

@PreviewTest
@Preview(name = "Cover landscape", widthDp = 800, heightDp = 360, apiLevel = 36, showBackground = true)
@Composable
fun SignInEmailStepLandscape() {
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

@PreviewTest
@Preview(name = "Cover landscape", widthDp = 800, heightDp = 360, apiLevel = 36, showBackground = true)
@Composable
fun SignInCodeStepLandscape() {
    SrokaTheme(darkTheme = false) {
        AuthScreen(
            state = AuthUiState(
                step = AuthStep.CODE,
                email = "magpie@example.com",
                code = "12",
                serverUrl = "https://api.sroka.app",
            ),
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

@PreviewTest
@FoldablePreviews
@Preview(name = "Tablet landscape", widthDp = 1280, heightDp = 800, apiLevel = 36, showBackground = true)
@Composable
fun SignInCodeStep() {
    SrokaTheme(darkTheme = false) {
        AuthScreen(
            state = AuthUiState(
                step = AuthStep.CODE,
                email = "magpie@example.com",
                code = "12",
                serverUrl = "https://api.sroka.app",
            ),
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
