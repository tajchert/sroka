package app.sroka.feature.library.impl.list

import app.sroka.core.designsystem.icon.SrokaIcons
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.theme.srokaColors
import app.sroka.core.model.ItemKind
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.feature.library.impl.R
import coil3.compose.AsyncImage
import java.io.File
import kotlin.math.ceil

/**
 * The one exception a row flags, most urgent first (proposals 02/03). Normal states (ready, downloaded,
 * unread/read) flag nothing. Shown as a badge on the thumbnail corner, except [PREPARING], which replaces
 * the tile's letter with a small spinner. No status changes the row's height.
 */
internal enum class RowStatus {
    /** Any un-pushed local change (save, tags, favourite, other): "Waiting to sync". */
    SYNC_PENDING,

    /** The server could not save the text: "Couldn't save the text" (the retry button shows too). */
    FAILED,

    /** Partial copy of the page: "Partial copy". */
    PARTIAL,

    /** Partial copy because the page is for subscribers (`paywalled`): "Preview only". */
    PREVIEW_ONLY,

    /** The server is still parsing the page: "Preparing…". */
    PREPARING,

    /** Queued or downloading to this device: "Downloading". */
    DOWNLOADING,

    /** Parsed on the server but not on this device and not queued: "Not on this device". */
    NOT_DOWNLOADED,
}

/** Priority: sync-pending > failed > partial > preparing > downloading > not-downloaded; else null (nothing to flag). */
internal fun rowStatus(item: ItemSummary): RowStatus? = when {
    item.pendingChange != null -> RowStatus.SYNC_PENDING
    item.parseStatus == ParseStatus.FAILED -> RowStatus.FAILED
    item.parseStatus == ParseStatus.PARTIAL && item.parseError == PAYWALLED -> RowStatus.PREVIEW_ONLY
    item.parseStatus == ParseStatus.PARTIAL -> RowStatus.PARTIAL
    item.parseStatus == ParseStatus.PENDING -> RowStatus.PREPARING
    item.offline == OfflineState.DOWNLOADING || item.offline == OfflineState.QUEUED -> RowStatus.DOWNLOADING
    item.offline == OfflineState.AVAILABLE_REMOTE -> RowStatus.NOT_DOWNLOADED
    else -> null
}

/** Server parse error of a subscriber-only page. */
private const val PAYWALLED = "paywalled"

/** Reading progress below this (2%) counts as unread; at or above [READ_FROM] as read. */
internal const val IN_PROGRESS_FROM = 0.02f
internal const val READ_FROM = 0.98f

internal enum class ReadState { UNREAD, IN_PROGRESS, READ }

internal fun readState(progress: Float): ReadState = when {
    progress >= READ_FROM -> ReadState.READ
    progress >= IN_PROGRESS_FROM -> ReadState.IN_PROGRESS
    else -> ReadState.UNREAD
}

/** Whole minutes left, rounded up, at least 1 (the tolerance keeps `10 * (1 - 0.9f)` at 1, not 2). */
internal fun minutesLeft(readingMinutes: Int, progress: Float): Int =
    ceil(readingMinutes * (1.0 - progress.toDouble()) - 1e-6).toInt().coerceAtLeast(1)

private val BadgeSize = 18.dp
private val BadgeRing = 2.dp

/**
 * One list row (proposals 02/03): thumbnail, title (2 lines), one meta line. Exceptions are a badge on the
 * thumbnail ([rowStatus]); a failed row also gets a trailing retry button ([onRetry]) in place of the star.
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
    onRetry: (() -> Unit)? = null,
) {
    val rowColor = when {
        selected -> MaterialTheme.colorScheme.primaryContainer
        rounded -> MaterialTheme.colorScheme.background // two-pane list: only the open row has a card
        else -> MaterialTheme.colorScheme.surface
    }
    val status = rowStatus(item)
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = if (rounded) RoundedCornerShape(16.dp) else RectangleShape,
        color = if (rounded && !selected) Color.Transparent else rowColor,
        tonalElevation = 0.dp,
        shadowElevation = 0.dp,
        border = null,
    ) {
        Row(
            Modifier
                .combinedClickable(onClick = onClick, onLongClick = onLongClick)
                .fillMaxWidth()
                .padding(start = 16.dp, end = 4.dp, top = 12.dp, bottom = 12.dp),
        ) {
            Box(Modifier.padding(end = 16.dp)) { Thumbnail(item, status, ringColor = rowColor) }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    item.displayTitle,
                    style = MaterialTheme.typography.titleMedium,
                    color = if (selected) MaterialTheme.colorScheme.onPrimaryContainer else Color.Unspecified,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                MetaLine(item)
            }
            // Constant 48dp trailing slot on every row (star, retry or empty), so no state changes the
            // title width and so never wraps a title or grows the row.
            Box(Modifier.size(48.dp)) {
                if (status == RowStatus.FAILED && onRetry != null) {
                    IconButton(onClick = onRetry, modifier = Modifier.matchParentSize()) {
                        Icon(
                            SrokaIcons.Refresh,
                            contentDescription = stringResource(R.string.feature_library_row_retry),
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    }
                } else if (item.isFavorite) {
                    Icon(
                        SrokaIcons.StarFilled,
                        contentDescription = stringResource(R.string.feature_library_row_favorite),
                        modifier = Modifier.align(Alignment.TopCenter).padding(top = 2.dp).size(20.dp),
                        tint = MaterialTheme.colorScheme.tertiary,
                    )
                }
            }
        }
    }
}

/** Thumbnail with its overlays: progress bar along the bottom edge, status badge on the top-end corner. */
@Composable
private fun Thumbnail(item: ItemSummary, status: RowStatus?, ringColor: Color) {
    val preparing = status == RowStatus.PREPARING
    Box(Modifier.size(56.dp)) {
        ThumbnailImage(item, showLetter = !preparing)
        if (preparing) {
            val label = stringResource(R.string.feature_library_status_preparing)
            CircularProgressIndicator(
                modifier = Modifier.align(Alignment.Center).size(24.dp).semantics { contentDescription = label },
                strokeWidth = 2.5.dp,
                color = MaterialTheme.colorScheme.primary,
            )
        }
        if (readState(item.progress) == ReadState.IN_PROGRESS) {
            Box(
                Modifier
                    .matchParentSize()
                    .clip(RoundedCornerShape(8.dp)),
                contentAlignment = Alignment.BottomStart,
            ) {
                Box(Modifier.fillMaxWidth().height(3.dp).background(Color.Black.copy(alpha = 0.45f))) {
                    Box(
                        Modifier
                            .fillMaxWidth(item.progress.coerceIn(0f, 1f))
                            .fillMaxHeight()
                            .background(MaterialTheme.srokaColors.progress),
                    )
                }
            }
        }
        if (status != null && !preparing) {
            StatusBadge(status, ringColor, Modifier.align(Alignment.TopEnd).offset(x = 6.dp, y = (-6).dp))
        }
    }
}

/** Icon chip (18dp) with a ring in the row's colour, so it reads on any image. One icon + label per state. */
@Composable
private fun StatusBadge(status: RowStatus, ringColor: Color, modifier: Modifier = Modifier) {
    val extended = MaterialTheme.srokaColors
    val scheme = MaterialTheme.colorScheme
    val (icon: ImageVector, label: Int) = when (status) {
        RowStatus.SYNC_PENDING -> SrokaIcons.Sync to R.string.feature_library_status_sync_waiting
        RowStatus.FAILED -> SrokaIcons.ErrorFilled to R.string.feature_library_status_failed
        RowStatus.PARTIAL -> SrokaIcons.WarningFilled to R.string.feature_library_status_partial
        RowStatus.PREVIEW_ONLY -> SrokaIcons.Lock to R.string.feature_library_status_preview_only
        RowStatus.PREPARING -> SrokaIcons.Schedule to R.string.feature_library_status_preparing // not drawn: spinner
        RowStatus.DOWNLOADING -> SrokaIcons.Download to R.string.feature_library_status_downloading_badge
        RowStatus.NOT_DOWNLOADED -> SrokaIcons.CloudOff to R.string.feature_library_status_not_on_device
    }
    val (container: Color, content: Color) = when (status) {
        RowStatus.SYNC_PENDING, RowStatus.PARTIAL, RowStatus.PREVIEW_ONLY, RowStatus.PREPARING -> extended.warningContainer to extended.warning
        RowStatus.FAILED -> scheme.errorContainer to scheme.onErrorContainer
        RowStatus.DOWNLOADING -> scheme.primaryContainer to scheme.onPrimaryContainer
        RowStatus.NOT_DOWNLOADED -> scheme.surfaceContainerHighest to scheme.onSurfaceVariant
    }
    Box(
        modifier.size(BadgeSize + BadgeRing * 2).background(ringColor, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(BadgeSize).background(container, CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = stringResource(label), modifier = Modifier.size(12.dp), tint = content)
        }
    }
}

@Composable
private fun ThumbnailImage(item: ItemSummary, showLetter: Boolean) {
    val shape = RoundedCornerShape(8.dp)
    val path = item.thumbnailPath
    if (item.kind == ItemKind.PDF && path != null) {
        // First-page preview: the top of the page, with a small PDF badge.
        Box(Modifier.size(56.dp).clip(shape).background(Color.White)) {
            AsyncImage(
                model = File(path),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                alignment = Alignment.TopCenter,
                modifier = Modifier.matchParentSize(),
            )
            Icon(
                SrokaIcons.PictureAsPdf,
                contentDescription = stringResource(R.string.feature_library_row_pdf_icon),
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(2.dp)
                    .size(18.dp)
                    .background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(4.dp))
                    .padding(1.dp),
                tint = MaterialTheme.colorScheme.onPrimaryContainer,
            )
        }
    } else if (item.kind == ItemKind.PDF) {
        // No preview (older uploads, or rendering failed): an icon tile instead.
        Box(
            Modifier.size(56.dp).clip(shape).background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                SrokaIcons.PictureAsPdf,
                contentDescription = stringResource(R.string.feature_library_row_pdf_icon),
                modifier = Modifier.size(28.dp),
                tint = MaterialTheme.colorScheme.onPrimaryContainer,
            )
        }
    } else if (path != null) {
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
            if (showLetter) {
                Text(
                    item.domain.firstOrNull { it.isLetterOrDigit() }?.uppercase() ?: "",
                    style = MaterialTheme.typography.titleLarge,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
}

/** `domain · N min`, `domain · N min left` (2–98%), or `domain · ✓ Read` (98%+); PDFs show their size. */
@Composable
private fun MetaLine(item: ItemSummary) {
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    val style = MaterialTheme.typography.bodyMedium
    if (item.kind != ItemKind.PDF && readState(item.progress) == ReadState.READ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                stringResource(R.string.feature_library_row_meta_domain, item.domain),
                style = style,
                color = color,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Icon(SrokaIcons.Check, contentDescription = null, modifier = Modifier.size(16.dp), tint = color)
            Text(stringResource(R.string.feature_library_row_read), style = style, color = color, maxLines = 1)
        }
    } else {
        Text(metaText(item), style = style, color = color, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun metaText(item: ItemSummary): String {
    val minutes = item.readingMinutes
    return when {
        item.kind == ItemKind.PDF ->
            item.fileSize?.let { stringResource(R.string.feature_library_row_pdf_meta, formatFileSize(it)) }
                ?: stringResource(R.string.feature_library_row_pdf)
        minutes != null && readState(item.progress) == ReadState.IN_PROGRESS ->
            stringResource(R.string.feature_library_row_meta_minutes_left, item.domain, minutesLeft(minutes, item.progress))
        minutes != null -> stringResource(R.string.feature_library_row_meta_minutes, item.domain, minutes)
        else -> item.domain
    }
}
