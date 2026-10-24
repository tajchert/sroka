package app.sroka.feature.library.impl.list

import app.sroka.core.designsystem.icon.SrokaIcons
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.theme.srokaColors
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.PendingChange
import app.sroka.feature.library.impl.R
import coil3.compose.AsyncImage
import java.io.File

/** The optional status line of a row (R6), most urgent first. */
internal enum class RowStatus {
    SAVE_WAITING,
    TAGS_WAITING,
    FAVORITE_WAITING,
    CHANGE_WAITING,
    PARTIAL,
    DOWNLOADING,
    OFFLINE,
}

/** Pending local change, else partial parse, else downloading/queued, else downloaded, else none. */
internal fun rowStatus(item: ItemSummary): RowStatus? = when {
    item.pendingChange == PendingChange.SAVE -> RowStatus.SAVE_WAITING
    item.pendingChange == PendingChange.TAGS -> RowStatus.TAGS_WAITING
    item.pendingChange == PendingChange.FAVORITE -> RowStatus.FAVORITE_WAITING
    item.pendingChange != null -> RowStatus.CHANGE_WAITING
    item.parseStatus == ParseStatus.PARTIAL -> RowStatus.PARTIAL
    item.offline == OfflineState.DOWNLOADING || item.offline == OfflineState.QUEUED -> RowStatus.DOWNLOADING
    item.offline == OfflineState.DOWNLOADED -> RowStatus.OFFLINE
    else -> null
}

/**
 * One list row (R6): thumbnail, title, `domain · N min`, status line, trailing star when favourite.
 * [selected] highlights the article open in the detail pane (R13): `primaryContainer` background and
 * `onPrimaryContainer` title; [rounded] gives the row 16dp corners (two-pane list).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun ItemRow(
    item: ItemSummary,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    rounded: Boolean = false,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = if (rounded) RoundedCornerShape(16.dp) else RectangleShape,
        color = when {
            selected -> MaterialTheme.colorScheme.primaryContainer
            rounded -> Color.Transparent // two-pane list: only the open row has a card
            else -> MaterialTheme.colorScheme.surface
        },
        tonalElevation = 0.dp,
        shadowElevation = 0.dp,
        border = null,
    ) {
        Row(
            Modifier
                .combinedClickable(onClick = onClick, onLongClick = onLongClick)
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Thumbnail(item)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    item.displayTitle,
                    style = MaterialTheme.typography.titleMedium,
                    color = if (selected) MaterialTheme.colorScheme.onPrimaryContainer else Color.Unspecified,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    metaText(item),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                rowStatus(item)?.let { StatusLine(it) }
            }
            if (item.isFavorite) {
                Icon(
                    SrokaIcons.StarFilled,
                    contentDescription = stringResource(R.string.feature_library_row_favorite),
                    modifier = Modifier.size(20.dp),
                    tint = MaterialTheme.colorScheme.tertiary,
                )
            }
        }
    }
}

@Composable
private fun Thumbnail(item: ItemSummary) {
    val shape = RoundedCornerShape(8.dp)
    val path = item.thumbnailPath
    if (path != null) {
        AsyncImage(
            model = File(path),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.size(56.dp).clip(shape),
        )
    } else {
        Box(
            Modifier.size(56.dp).clip(shape).background(MaterialTheme.colorScheme.surfaceContainerHigh),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                item.domain.firstOrNull { it.isLetterOrDigit() }?.uppercase() ?: "",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.primary,
            )
        }
    }
}

@Composable
private fun metaText(item: ItemSummary): String = when {
    item.parseStatus == ParseStatus.PENDING -> "${item.domain} · ${stringResource(R.string.feature_library_row_processing)}"
    item.parseStatus == ParseStatus.FAILED -> "${item.domain} · ${stringResource(R.string.feature_library_row_parse_failed)}"
    item.readingMinutes != null ->
        stringResource(R.string.feature_library_row_meta_minutes, item.domain, item.readingMinutes!!)
    else -> item.domain
}

@Composable
private fun StatusLine(status: RowStatus) {
    val warning = MaterialTheme.srokaColors.warning
    val primary = MaterialTheme.colorScheme.primary
    val (icon: ImageVector, label: Int, color: Color) = when (status) {
        RowStatus.SAVE_WAITING -> Triple(SrokaIcons.ScheduleFilled, R.string.feature_library_status_save_waiting, warning)
        RowStatus.TAGS_WAITING -> Triple(SrokaIcons.ScheduleFilled, R.string.feature_library_status_tags_waiting, warning)
        RowStatus.FAVORITE_WAITING -> Triple(SrokaIcons.ScheduleFilled, R.string.feature_library_status_favorite_waiting, warning)
        RowStatus.CHANGE_WAITING -> Triple(SrokaIcons.ScheduleFilled, R.string.feature_library_status_change_waiting, warning)
        RowStatus.PARTIAL -> Triple(SrokaIcons.WarningFilled, R.string.feature_library_status_partial, warning)
        RowStatus.DOWNLOADING -> Triple(SrokaIcons.DownloadingFilled, R.string.feature_library_status_row_downloading, primary)
        RowStatus.OFFLINE -> Triple(SrokaIcons.OfflinePinFilled, R.string.feature_library_row_available_offline, primary)
    }
    Row(
        Modifier.padding(top = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp), tint = color)
        Text(stringResource(label), style = MaterialTheme.typography.labelMedium, color = color)
    }
}
