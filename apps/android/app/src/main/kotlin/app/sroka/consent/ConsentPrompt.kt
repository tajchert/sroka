package app.sroka.consent

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.R
import app.sroka.core.ui.LegalLinks
import app.sroka.core.ui.openExternalLink

/**
 * First-run analytics consent (repo-root D15). Shown once, only in builds that carry telemetry,
 * while the signed-in library is on screen; either button records the decision.
 */
@Composable
fun ConsentPromptHost(viewModel: ConsentPromptViewModel = hiltViewModel()) {
    val show by viewModel.showPrompt.collectAsStateWithLifecycle()
    if (show) {
        val context = LocalContext.current
        ConsentPrompt(
            onAllow = { viewModel.decide(allow = true) },
            onDecline = { viewModel.decide(allow = false) },
            onOpenPrivacyPolicy = { openExternalLink(context, LegalLinks.PRIVACY_POLICY) },
        )
    }
}

/** Stateless prompt. Not dismissable by tapping outside or Back: the user picks one of the buttons. */
@Composable
fun ConsentPrompt(
    onAllow: () -> Unit,
    onDecline: () -> Unit,
    onOpenPrivacyPolicy: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = {},
        title = { Text(stringResource(R.string.consent_title)) },
        text = {
            androidx.compose.foundation.layout.Column {
                Text(stringResource(R.string.consent_body))
                TextButton(onClick = onOpenPrivacyPolicy) { Text(stringResource(R.string.consent_privacy_policy)) }
            }
        },
        confirmButton = { TextButton(onClick = onAllow) { Text(stringResource(R.string.consent_allow)) } },
        dismissButton = { TextButton(onClick = onDecline) { Text(stringResource(R.string.consent_decline)) } },
    )
}
