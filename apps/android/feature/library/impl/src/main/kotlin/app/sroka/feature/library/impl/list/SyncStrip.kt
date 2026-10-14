package app.sroka.feature.library.impl.list

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.sroka.core.model.SyncErrorKind
import app.sroka.core.model.SyncPhase
import app.sroka.feature.library.impl.R

/**
 * Progress under the top bar (DECISIONS A11): a linear indicator while syncing/downloading plus a
 * one-line status. Renders nothing when idle.
 */
@Composable
internal fun SyncStrip(
    phase: SyncPhase,
    needsSignIn: Boolean,
    onSignIn: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val text: String? = when {
        needsSignIn -> stringResource(R.string.feature_library_status_sign_in)
        phase is SyncPhase.Syncing -> stringResource(R.string.feature_library_status_syncing)
        phase is SyncPhase.Downloading ->
            if (phase.currentTitle.isNullOrBlank()) {
                stringResource(R.string.feature_library_status_downloading, phase.done, phase.total)
            } else {
                stringResource(R.string.feature_library_status_downloading_title, phase.done, phase.total, phase.currentTitle!!)
            }
        phase is SyncPhase.Offline -> stringResource(R.string.feature_library_status_offline)
        phase is SyncPhase.Error && phase.kind == SyncErrorKind.NETWORK ->
            stringResource(R.string.feature_library_status_network_error)
        phase is SyncPhase.Error && phase.kind == SyncErrorKind.SERVER ->
            stringResource(R.string.feature_library_status_server_error)
        else -> null
    }
    if (text == null) return
    Surface(modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.surfaceContainer) {
        Column {
            when {
                phase is SyncPhase.Downloading && phase.total > 0 ->
                    LinearProgressIndicator(
                        progress = { (phase.done.toFloat() / phase.total).coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                phase is SyncPhase.Syncing || phase is SyncPhase.Downloading ->
                    LinearProgressIndicator(Modifier.fillMaxWidth())
            }
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).padding(vertical = 10.dp),
                )
                if (needsSignIn) {
                    TextButton(onClick = onSignIn) { Text(stringResource(R.string.feature_library_sign_in)) }
                }
            }
        }
    }
}
