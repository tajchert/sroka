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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.core.designsystem.theme.SrokaTheme
import android.net.Uri
import androidx.core.content.IntentCompat
import app.sroka.feature.library.impl.save.PdfShareHost
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
        val pdfUris = if (isPdfShare(intent)) sharedPdfUris(intent) else null

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
            SrokaTheme(darkTheme = darkTheme) {
                if (pdfUris != null) {
                    PdfShareHost(
                        uris = pdfUris,
                        onFinish = ::finish,
                        onSignIn = {
                            startActivity(
                                Intent(this, MainActivity::class.java)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                            )
                            finish()
                        },
                    )
                    return@SrokaTheme
                }
                SaveSheetHost(
                    sharedText = sharedText,
                    subject = subject,
                    onFinish = ::finish,
                    onOpenApp = { itemId ->
                        startActivity(
                            Intent(this, MainActivity::class.java)
                                .putExtra(EXTRA_OPEN_ITEM_ID, itemId)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                        )
                        finish()
                    },
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

/** True when [intent] shares PDF file(s) rather than a link. */
internal fun isPdfShare(intent: Intent): Boolean =
    (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE) && intent.type == "application/pdf"

/**
 * The PDF content URIs of a `SEND` / `SEND_MULTIPLE` intent: `EXTRA_STREAM`, else the ClipData items.
 * The sender's read grant lasts while the activity lives, and the uploader copies the files in `enqueue`.
 */
internal fun sharedPdfUris(intent: Intent): List<Uri> {
    val fromExtra: List<Uri> = if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
        IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
    } else {
        listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
    }
    val uris = fromExtra.ifEmpty {
        val clip = intent.clipData
        (0 until (clip?.itemCount ?: 0)).mapNotNull { clip!!.getItemAt(it).uri }
    }
    return uris.distinct()
}

/**
 * Intent extra on the MainActivity launch from the save sheet ("Open Sroka" / "Continue reading"):
 * the item id whose reader should open. The nav host does not consume it yet (see LEDGER T4 note).
 */
const val EXTRA_OPEN_ITEM_ID = "app.sroka.extra.OPEN_ITEM_ID"

private val LIGHT_SCRIM = Color.argb(0xe6, 0xFF, 0xFF, 0xFF)
private val DARK_SCRIM = Color.argb(0x80, 0x1b, 0x1b, 0x1b)
