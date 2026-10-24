package app.sroka.feature.library.impl.list

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.theme.srokaColors
import app.sroka.core.model.SyncPhase
import app.sroka.core.model.SyncStatus
import app.sroka.feature.library.impl.R

/** The one card shown above the list (R7). */
internal sealed interface StatusCard {
    /** Session expired: sign-in prompt (actionable, so it comes first). */
    data object SignIn : StatusCard

    data class Resync(val fraction: Float?) : StatusCard

    data class Offline(val pendingChanges: Int) : StatusCard

    data class Downloading(val done: Int, val total: Int) : StatusCard
}

/** Resync > Offline > Downloading; idle, routine sync and errors show no card (pull-to-refresh covers sync). */
internal fun selectStatusCard(status: SyncStatus, needsSignIn: Boolean): StatusCard? {
    val phase = status.phase
    return when {
        needsSignIn -> StatusCard.SignIn
        phase is SyncPhase.Resyncing -> StatusCard.Resync(phase.fraction)
        phase is SyncPhase.Offline -> StatusCard.Offline(status.pendingOps)
        phase is SyncPhase.Downloading -> StatusCard.Downloading(phase.done, phase.total)
        else -> null
    }
}

/** Animated host: the card collapses when it goes away, keeping the last content while it animates out. */
@Composable
internal fun StatusCards(card: StatusCard?, onSignIn: () -> Unit, modifier: Modifier = Modifier) {
    var last by remember { mutableStateOf(card) }
    if (card != null) last = card
    AnimatedVisibility(
        visible = card != null,
        modifier = modifier,
        enter = fadeIn() + expandVertically(),
        exit = fadeOut() + shrinkVertically(),
    ) {
        when (val c = card ?: last) {
            is StatusCard.Downloading -> DownloadingCard(c)
            is StatusCard.Offline -> OfflineCard(c)
            is StatusCard.Resync -> ResyncCard(c)
            StatusCard.SignIn -> SignInCard(onSignIn)
            null -> Unit
        }
    }
}

private val CardMargin = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 8.dp)
private val CardShape = RoundedCornerShape(16.dp)

@Composable
private fun DownloadingCard(card: StatusCard.Downloading) {
    Surface(CardMargin.fillMaxWidth(), shape = CardShape, color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Rounded.Download, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
                Text(
                    stringResource(R.string.feature_library_card_downloading),
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    stringResource(R.string.feature_library_card_downloading_count, card.done, card.total),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            LinearProgressIndicator(
                progress = { if (card.total > 0) (card.done.toFloat() / card.total).coerceIn(0f, 1f) else 0f },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun OfflineCard(card: StatusCard.Offline) {
    val colors = MaterialTheme.srokaColors
    Surface(CardMargin.fillMaxWidth(), shape = CardShape, color = colors.warningContainer, contentColor = colors.warning) {
        Row(
            Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Rounded.CloudOff, null, Modifier.size(20.dp))
            Text(
                if (card.pendingChanges > 0) {
                    pluralStringResource(R.plurals.feature_library_card_offline_changes, card.pendingChanges, card.pendingChanges)
                } else {
                    stringResource(R.string.feature_library_card_offline_none)
                },
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun ResyncCard(card: StatusCard.Resync) {
    val colors = MaterialTheme.srokaColors
    val fraction = card.fraction
    Surface(CardMargin.fillMaxWidth(), shape = CardShape, color = colors.brand, contentColor = colors.onBrand) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Rounded.Sync, null, Modifier.size(24.dp))
                Text(
                    stringResource(R.string.feature_library_card_resync_title),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                )
                if (fraction != null) {
                    Text(
                        stringResource(R.string.feature_library_card_resync_percent, (fraction.coerceIn(0f, 1f) * 100).toInt()),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
            Text(stringResource(R.string.feature_library_card_resync_body), style = MaterialTheme.typography.bodyMedium)
            val track = colors.onBrand.copy(alpha = 0.25f)
            if (fraction != null) {
                LinearProgressIndicator(
                    progress = { fraction.coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth(),
                    color = colors.progress,
                    trackColor = track,
                )
            } else {
                LinearProgressIndicator(Modifier.fillMaxWidth(), color = colors.progress, trackColor = track)
            }
        }
    }
}

@Composable
private fun SignInCard(onSignIn: () -> Unit) {
    Surface(CardMargin.fillMaxWidth(), shape = CardShape, color = MaterialTheme.colorScheme.errorContainer) {
        Row(
            Modifier.padding(start = 16.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Rounded.Lock, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onErrorContainer)
            Text(
                stringResource(R.string.feature_library_status_sign_in),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onErrorContainer,
                modifier = Modifier.weight(1f).padding(vertical = 10.dp),
            )
            TextButton(onClick = onSignIn) { Text(stringResource(R.string.feature_library_sign_in)) }
        }
    }
}
