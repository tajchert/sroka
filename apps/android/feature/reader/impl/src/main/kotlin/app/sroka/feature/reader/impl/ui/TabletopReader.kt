package app.sroka.feature.reader.impl.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.icon.SrokaIcons
import app.sroka.core.designsystem.theme.srokaColors
import app.sroka.feature.reader.impl.R
import app.sroka.feature.reader.impl.percentRead

internal val TabletopSidePadding = 64.dp
internal val TabletopTitleHeight = 40.dp
private val ProgressLineHeight = 3.dp

/** Space the article leaves above itself: status bar, 3dp progress line, title line. */
internal fun tabletopArticleTop(statusBar: Dp): Dp = statusBar + ProgressLineHeight + TabletopTitleHeight

/** Modifier placing the article WebView (or a stub) between the top chrome and the hinge. */
internal fun Modifier.tabletopArticle(statusBar: Dp, hingeTop: Dp): Modifier {
    val top = tabletopArticleTop(statusBar)
    return this
        .padding(start = TabletopSidePadding, end = TabletopSidePadding, top = top)
        .fillMaxWidth()
        .height((hingeTop - top).coerceAtLeast(0.dp))
}

/**
 * Tabletop chrome drawn over a full-window Box that also holds the article (R15.2): the 3dp progress line and
 * "site · title" line at the top, and the controls panel from [hingeBottom] down.
 */
@Composable
internal fun TabletopChrome(
    statusBar: Dp,
    hingeBottom: Dp,
    titleLine: String,
    progress: Float,
    controls: @Composable ColumnScope.() -> Unit,
) {
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxWidth().padding(top = statusBar)) {
            val colors = MaterialTheme.srokaColors
            Box(Modifier.fillMaxWidth().height(ProgressLineHeight).background(colors.progressTrack)) {
                Box(
                    Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(progress.coerceIn(0f, 1f))
                        .background(colors.progress),
                )
            }
            Box(
                Modifier.fillMaxWidth().height(TabletopTitleHeight).padding(horizontal = TabletopSidePadding),
                Alignment.CenterStart,
            ) {
                Text(
                    titleLine,
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Column(
            Modifier
                .padding(top = hingeBottom)
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surfaceContainer)
                // Scrolls when the content is taller than the space below the hinge (never clips Up next).
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(horizontal = 32.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(22.dp),
            content = controls,
        )
    }
}

/** The next unread item shown on the "Up next" card. */
internal data class UpNextCard(val title: String)

/** Stateless controls panel contents (progress scrubber, text size, actions, up next). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ColumnScope.TabletopControls(
    progress: Float,
    minutesLeft: Int?,
    textSizePx: Int,
    isFavorite: Boolean,
    isArchived: Boolean,
    upNext: UpNextCard?,
    onScrub: (Float) -> Unit,
    onTextSmaller: () -> Unit,
    onTextLarger: () -> Unit,
    onFavorite: () -> Unit,
    onArchive: () -> Unit,
    onTags: () -> Unit,
    onReadNext: () -> Unit,
) {
    var dragging by remember { mutableStateOf<Float?>(null) }
    val shown = dragging ?: progress.coerceIn(0f, 1f)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(
                stringResource(R.string.feature_reader_tabletop_percent_read, percentRead(shown)),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            if (minutesLeft != null) {
                Text(
                    stringResource(R.string.feature_reader_tabletop_min_left, minutesLeft),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        val scrubLabel = stringResource(R.string.feature_reader_tabletop_scrubber)
        val sliderColors = SliderDefaults.colors(
            activeTrackColor = MaterialTheme.colorScheme.primary,
            inactiveTrackColor = MaterialTheme.colorScheme.primaryContainer,
        )
        Slider(
            value = shown,
            onValueChange = { dragging = it; onScrub(it) },
            onValueChangeFinished = { dragging = null },
            modifier = Modifier.fillMaxWidth().semantics { contentDescription = scrubLabel },
            colors = sliderColors,
            thumb = {
                Box(
                    Modifier
                        .size(width = 4.dp, height = 44.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(MaterialTheme.colorScheme.primary),
                )
            },
            track = { state ->
                SliderDefaults.Track(
                    sliderState = state,
                    modifier = Modifier.height(16.dp),
                    colors = sliderColors,
                    drawStopIndicator = null,
                    thumbTrackGapSize = 4.dp,
                )
            },
        )
    }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                .padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val smaller = stringResource(R.string.feature_reader_tabletop_text_smaller)
            val larger = stringResource(R.string.feature_reader_tabletop_text_larger)
            Box(
                Modifier.size(48.dp).clip(CircleShape).clickable(onClick = onTextSmaller)
                    .semantics { contentDescription = smaller },
                Alignment.Center,
            ) { Text("A−", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface) }
            Text(
                stringResource(R.string.feature_reader_tabletop_text_size_px, textSizePx),
                modifier = Modifier.width(64.dp),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            Box(
                Modifier.size(48.dp).clip(CircleShape).clickable(onClick = onTextLarger)
                    .semantics { contentDescription = larger },
                Alignment.Center,
            ) { Text("A+", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface) }
        }
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End)) {
            TonalCircle(
                if (isFavorite) SrokaIcons.StarFilled else SrokaIcons.Star,
                stringResource(if (isFavorite) R.string.feature_reader_unfavorite else R.string.feature_reader_favorite),
                onFavorite,
            )
            TonalCircle(
                if (isArchived) SrokaIcons.Unarchive else SrokaIcons.Archive,
                stringResource(if (isArchived) R.string.feature_reader_unarchive else R.string.feature_reader_archive),
                onArchive,
            )
            TonalCircle(SrokaIcons.Label, stringResource(R.string.feature_reader_edit_tags), onTags)
        }
    }
    if (upNext != null) {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(
                Modifier.size(48.dp).clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.surfaceVariant),
                Alignment.Center,
            ) { Icon(SrokaIcons.Article, null, tint = MaterialTheme.colorScheme.onSurfaceVariant) }
            Column(Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.feature_reader_tabletop_up_next),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
                Text(
                    upNext.title,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            FilledTonalButton(onClick = onReadNext) { Text(stringResource(R.string.feature_reader_tabletop_read)) }
        }
    }
}

@Composable
private fun TonalCircle(icon: ImageVector, description: String, onClick: () -> Unit) {
    FilledTonalIconButton(onClick = onClick, modifier = Modifier.size(48.dp)) { Icon(icon, description) }
}
