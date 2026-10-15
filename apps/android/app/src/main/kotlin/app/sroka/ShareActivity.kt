package app.sroka

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.core.designsystem.theme.SrokaTheme
import app.sroka.feature.library.impl.save.SaveSheetHost
import dagger.hilt.android.AndroidEntryPoint

/**
 * Target of the system share sheet (ACTION_SEND text/plain). Translucent, so the save sheet
 * appears over the app the user shared from; it saves locally and finishes on its own.
 */
@AndroidEntryPoint
class ShareActivity : ComponentActivity() {

    private val viewModel: MainActivityViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)

        setContent {
            val uiState by viewModel.uiState.collectAsStateWithLifecycle()
            SrokaTheme(
                darkTheme = uiState.shouldUseDarkTheme(isSystemInDarkTheme()),
                dynamicColor = uiState.shouldUseDynamicColor(),
            ) {
                SaveSheetHost(
                    sharedText = sharedText,
                    subject = subject,
                    onFinish = ::finish,
                    onSignIn = {
                        startActivity(
                            Intent(this, MainActivity::class.java)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                        )
                        finish()
                    },
                )
            }
        }
    }
}
