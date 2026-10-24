package app.sroka

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import android.graphics.Color
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
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

    /** Item id from the share sheet's "Open Sroka" / "Continue reading"; cleared once the nav host consumed it. */
    private var pendingOpenItemId by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        val splashScreen = installSplashScreen()
        super.onCreate(savedInstanceState)
        splashScreen.setKeepOnScreenCondition { viewModel.uiState.value is MainActivityUiState.Loading }

        enableEdgeToEdge()
        // A recreated activity (rotation) re-delivers the same intent; its extra was consumed already.
        if (savedInstanceState == null) pendingOpenItemId = takeOpenItemId(intent)

        setContent {
            val uiState by viewModel.uiState.collectAsStateWithLifecycle()
            val darkTheme = uiState.shouldUseDarkTheme(isSystemInDarkTheme())
            // Keep status/navigation bar icons in sync with the in-app theme choice, not the system's.
            DisposableEffect(darkTheme) {
                enableEdgeToEdge(
                    statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT) { darkTheme },
                    navigationBarStyle = SystemBarStyle.auto(LIGHT_SCRIM, DARK_SCRIM) { darkTheme },
                )
                onDispose {}
            }
            val state = uiState as? MainActivityUiState.Success
            SrokaTheme(
                darkTheme = darkTheme,
                dynamicColor = false,
            ) {
                if (state != null) SrokaApp(
                        session = state.session,
                        onUndoArchive = viewModel::unarchive,
                        openItemId = pendingOpenItemId,
                        onOpenItemConsumed = { pendingOpenItemId = null },
                    )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        takeOpenItemId(intent)?.let { pendingOpenItemId = it }
    }

    /** Reads and removes [EXTRA_OPEN_ITEM_ID] so a later recreation does not reopen the item. */
    private fun takeOpenItemId(intent: Intent?): String? {
        val id = intent?.getStringExtra(EXTRA_OPEN_ITEM_ID)?.takeIf { it.isNotBlank() }
        intent?.removeExtra(EXTRA_OPEN_ITEM_ID)
        // Relaunched from Recents: the extra is a replay of an old share deep link, not a new request.
        if (intent != null && intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        return id
    }
}

private val LIGHT_SCRIM = Color.argb(0xe6, 0xFF, 0xFF, 0xFF)
private val DARK_SCRIM = Color.argb(0x80, 0x1b, 0x1b, 0x1b)
