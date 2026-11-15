package app.sroka.feature.reader.impl.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.icon.SrokaIcons
import app.sroka.core.model.ItemSummary
import app.sroka.feature.reader.impl.EffectiveTheme
import app.sroka.feature.reader.impl.R
import coil3.compose.AsyncImage
import java.io.File

/**
 * The finish line shown over the blank space under an article once it is scrolled to its end: "Finished", the
 * primary "Archive & next" (plain "Archive" without a next item), "Keep", and the "Up next" preview.
 * An already archived item shows "Finished" and "Up next" only. Coloured from the reader [theme] so it sits
 * naturally on the page.
 */
@Composable
internal fun EndOfArticleCard(
    minutes: Int?,
    archived: Boolean,
    next: ItemSummary?,
    theme: EffectiveTheme,
    onArchive: () -> Unit,
    onKeep: () -> Unit,
    onOpenNext: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val bg = Color(theme.backgroundArgb)
    val fg = Color(theme.foregroundArgb)
    val muted = lerp(fg, bg, 0.4f)
    val shape = RoundedCornerShape(20.dp)
    Surface(
        modifier = modifier.padding(horizontal = 16.dp, vertical = 12.dp).widthIn(max = 560.dp).fillMaxWidth(),
        shape = shape,
        color = lerp(bg, fg, 0.06f),
        contentColor = fg,
        border = BorderStroke(1.dp, lerp(bg, fg, 0.14f)),
        shadowElevation = 2.dp,
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(SrokaIcons.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(24.dp))
                Text(
                    if (minutes != null) stringResource(R.string.feature_reader_finished_minutes, minutes) else stringResource(R.string.feature_reader_finished),
                    style = MaterialTheme.typography.titleMedium,
                    color = fg,
                )
            }
            if (!archived) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Button(onClick = onArchive) {
                        Icon(SrokaIcons.Archive, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(8.dp))
                        Text(stringResource(if (next != null) R.string.feature_reader_archive_next else R.string.feature_reader_archive))
                    }
                    TextButton(onClick = onKeep) { Text(stringResource(R.string.feature_reader_keep)) }
                }
            }
            if (next != null) {
                UpNextRow(next, fg, muted, onOpenNext)
            }
        }
    }
}

@Composable
private fun UpNextRow(next: ItemSummary, fg: Color, muted: Color, onClick: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(stringResource(R.string.feature_reader_up_next), style = MaterialTheme.typography.labelMedium, color = muted)
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .clickable(onClick = onClick),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            NextThumbnail(next)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    next.displayTitle,
                    style = MaterialTheme.typography.titleSmall,
                    color = fg,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                next.readingMinutes?.let {
                    Text(stringResource(R.string.feature_reader_up_next_minutes, it), style = MaterialTheme.typography.bodySmall, color = muted)
                }
            }
        }
    }
}

@Composable
private fun NextThumbnail(next: ItemSummary) {
    val shape = RoundedCornerShape(8.dp)
    val path = next.thumbnailPath
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
                next.domain.firstOrNull { it.isLetterOrDigit() }?.uppercase().orEmpty(),
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.primary,
            )
        }
    }
}
