package app.sroka

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.getValue
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.core.designsystem.theme.SrokaTheme
import app.sroka.navigation.SrokaApp
import dagger.hilt.android.AndroidEntryPoint

/**
 * Single activity. Keeps the splash screen until preferences and the session are known, so the
 * first frame has the right theme and the right start destination (sign-in vs. library).
 */
@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    private val viewModel: MainActivityViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        val splashScreen = installSplashScreen()
        super.onCreate(savedInstanceState)
        splashScreen.setKeepOnScreenCondition { viewModel.uiState.value is MainActivityUiState.Loading }

        enableEdgeToEdge()

        setContent {
            val uiState by viewModel.uiState.collectAsStateWithLifecycle()
            val state = uiState as? MainActivityUiState.Success
            SrokaTheme(
                darkTheme = uiState.shouldUseDarkTheme(isSystemInDarkTheme()),
                dynamicColor = uiState.shouldUseDynamicColor(),
            ) {
                if (state != null) SrokaApp(isSignedIn = state.isSignedIn)
            }
        }
    }
}
