package app.sroka.feature.library.impl.list

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DownloadDone
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.feature.library.impl.R
import coil3.compose.AsyncImage
import java.io.File

/** One list row (DECISIONS A11): title, `domain · N min`, up to two tags, right thumbnail, progress line. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun ItemRow(
    item: ItemSummary,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(modifier = modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick)) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        item.displayTitle,
                        style = MaterialTheme.typography.titleMedium,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    MetaLine(item)
                    if (item.tags.isNotEmpty()) {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            item.tags.take(MAX_ROW_TAGS).forEach { TagLabel(it) }
                        }
                    }
                }
                item.thumbnailPath?.let { path ->
                    AsyncImage(
                        model = File(path),
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.size(72.dp).clip(RoundedCornerShape(8.dp)),
                    )
                }
            }
            if (item.progress > 0f && item.progress < 1f) {
                LinearProgressIndicator(
                    progress = { item.progress },
                    modifier = Modifier.fillMaxWidth().height(2.dp),
                    gapSize = 0.dp,
                    drawStopIndicator = {},
                )
            } else {
                Box(Modifier.height(2.dp))
            }
        }
    }
}

@Composable
private fun MetaLine(item: ItemSummary) {
    val text = when {
        item.parseStatus == ParseStatus.PENDING -> "${item.domain} · ${stringResource(R.string.feature_library_row_processing)}"
        item.parseStatus == ParseStatus.FAILED -> "${item.domain} · ${stringResource(R.string.feature_library_row_parse_failed)}"
        item.readingMinutes != null ->
            stringResource(R.string.feature_library_row_meta_minutes, item.domain, item.readingMinutes!!)
        else -> item.domain
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            text,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        if (item.offline == OfflineState.DOWNLOADED) {
            Icon(
                Icons.Filled.DownloadDone,
                contentDescription = stringResource(R.string.feature_library_row_available_offline),
                modifier = Modifier.size(14.dp),
                tint = MaterialTheme.colorScheme.primary,
            )
        }
        if (item.isFavorite) {
            Icon(
                Icons.Filled.Star,
                contentDescription = stringResource(R.string.feature_library_row_favorite),
                modifier = Modifier.size(14.dp),
                tint = MaterialTheme.colorScheme.tertiary,
            )
        }
    }
}

@Composable
private fun TagLabel(name: String) {
    Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.secondaryContainer) {
        Text(
            name,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSecondaryContainer,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
        )
    }
}

private const val MAX_ROW_TAGS = 2
