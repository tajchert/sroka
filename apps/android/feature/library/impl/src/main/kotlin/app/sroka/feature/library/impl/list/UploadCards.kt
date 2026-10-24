package app.sroka.feature.library.impl.list

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.icon.SrokaIcons
import app.sroka.core.designsystem.theme.srokaColors
import app.sroka.core.model.PdfUpload
import app.sroka.core.model.PdfUploadError
import app.sroka.core.model.PdfUploadState
import app.sroka.feature.library.impl.R

/** What the "Uploading N PDFs" area above the list shows. */
sealed interface UploadCard {
    /** [fraction] is null while nothing has started sending (indeterminate bar). */
    data class Uploading(val count: Int, val fraction: Float?) : UploadCard

    /** Permanently failed uploads: the first file's name and error, [more] further failures. */
    data class Failed(val fileName: String, val error: PdfUploadError, val more: Int) : UploadCard {
        /** Only transient-looking errors are worth picking the file again for. */
        val canRetry: Boolean get() = error != PdfUploadError.TOO_LARGE && error != PdfUploadError.NOT_PDF
    }
}

/** Uploading card first (progress is weighted by file size), then the failed card; Done entries show nothing. */
internal fun selectUploadCards(uploads: List<PdfUpload>): List<UploadCard> {
    val cards = mutableListOf<UploadCard>()
    val active = uploads.filter { it.isActive }
    if (active.isNotEmpty()) {
        val started = active.any { it.state is PdfUploadState.Uploading }
        val total = active.sumOf { it.sizeBytes.coerceAtLeast(1L) }.toDouble()
        val sent = active.sumOf {
            val p = (it.state as? PdfUploadState.Uploading)?.progress ?: 0f
            it.sizeBytes.coerceAtLeast(1L) * p.coerceIn(0f, 1f).toDouble()
        }
        cards += UploadCard.Uploading(active.size, if (started) (sent / total).toFloat() else null)
    }
    val failed = uploads.filter { it.state is PdfUploadState.Failed }
    if (failed.isNotEmpty()) {
        val first = failed.first()
        cards += UploadCard.Failed(first.fileName, (first.state as PdfUploadState.Failed).error, failed.size - 1)
    }
    return cards
}

@StringRes
internal fun uploadErrorMessage(error: PdfUploadError): Int = when (error) {
    PdfUploadError.TOO_LARGE -> R.string.feature_library_upload_err_too_large
    PdfUploadError.NOT_PDF -> R.string.feature_library_upload_err_not_pdf
    PdfUploadError.STORAGE_FULL -> R.string.feature_library_upload_err_storage_full
    PdfUploadError.NETWORK -> R.string.feature_library_upload_err_network
    PdfUploadError.UNKNOWN -> R.string.feature_library_upload_err_unknown
    PdfUploadError.AUTH -> R.string.feature_library_upload_err_auth
}

/** "2.3 MB" / "840 KB" / "12 B"; decimal units, one decimal for MB and above. */
internal fun formatFileSize(bytes: Long): String = when {
    bytes >= 1_000_000L -> String.format(java.util.Locale.getDefault(), "%.1f MB", bytes / 1_000_000.0)
    bytes >= 1_000L -> String.format(java.util.Locale.getDefault(), "%d KB", Math.round(bytes / 1_000.0))
    else -> "$bytes B"
}

private val CardMargin = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 8.dp)
private val CardShape = RoundedCornerShape(16.dp)

@Composable
internal fun UploadCards(
    cards: List<UploadCard>,
    onRetry: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier) {
        cards.forEach { card ->
            when (card) {
                is UploadCard.Uploading -> UploadingCard(card)
                is UploadCard.Failed -> FailedCard(card, onRetry, onDismiss)
            }
        }
    }
}

@Composable
private fun UploadingCard(card: UploadCard.Uploading) {
    val title = pluralStringResource(R.plurals.feature_library_uploading_pdfs, card.count, card.count)
    Surface(CardMargin.fillMaxWidth(), shape = CardShape, color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column(
            Modifier.padding(horizontal = 16.dp, vertical = 14.dp).semantics(mergeDescendants = true) {},
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(SrokaIcons.UploadFile, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
                Text(title, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                card.fraction?.let {
                    Text(
                        stringResource(R.string.feature_library_card_resync_percent, (it * 100).toInt()),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            val fraction = card.fraction
            if (fraction == null) {
                LinearProgressIndicator(Modifier.fillMaxWidth())
            } else {
                LinearProgressIndicator(progress = { fraction.coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

@Composable
private fun FailedCard(card: UploadCard.Failed, onRetry: () -> Unit, onDismiss: () -> Unit) {
    val colors = MaterialTheme.srokaColors
    val file = if (card.more > 0) {
        stringResource(R.string.feature_library_upload_failed_more, card.fileName, card.more)
    } else {
        card.fileName
    }
    Surface(CardMargin.fillMaxWidth(), shape = CardShape, color = colors.warningContainer, contentColor = colors.warning) {
        Column(Modifier.padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 4.dp)) {
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(SrokaIcons.WarningFilled, null, Modifier.size(20.dp))
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.feature_library_upload_failed_title), style = MaterialTheme.typography.labelLarge)
                    Text(
                        stringResource(R.string.feature_library_upload_failed_file, file, stringResource(uploadErrorMessage(card.error))),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
            Row(Modifier.align(Alignment.End)) {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_library_upload_dismiss)) }
                if (card.canRetry) {
                    TextButton(onClick = onRetry) { Text(stringResource(R.string.feature_library_upload_retry)) }
                }
            }
        }
    }
}
