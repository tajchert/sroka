package app.sroka.feature.library.impl.save

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BookmarkAdded
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.LinkOff
import androidx.compose.material.icons.rounded.NewLabel
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.core.designsystem.theme.srokaColors
import app.sroka.core.model.Item
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.OfflineState
import app.sroka.feature.library.impl.R
import app.sroka.core.ui.tags.EditTagsSheet
import coil3.compose.AsyncImage
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlinx.coroutines.launch

/**
 * Share-target UI (screens 07/08): a bottom sheet over the app the user shared from. Host it in the
 * translucent, `excludeFromRecents` ShareActivity inside the app theme and pass the `ACTION_SEND` extras.
 * It dismisses itself 4 s after showing unless the user touched it.
 *
 * @param onFinish the sheet is done; finish the activity
 * @param onSignIn user chose "Sign in" while signed out; open the main activity
 * @param onOpenApp user chose "Open Sroka" / "Continue reading"; open the main activity, ideally on the
 *   reader for [itemId], and finish
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SaveSheetHost(
    sharedText: String?,
    subject: String?,
    onFinish: () -> Unit,
    onSignIn: () -> Unit = {},
    onOpenApp: (itemId: String) -> Unit = {},
    viewModel: SaveSheetViewModel = hiltViewModel(),
) {
    LaunchedEffect(sharedText, subject) { viewModel.start(sharedText, subject) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val item by viewModel.item.collectAsStateWithLifecycle()
    val recentTags by viewModel.recentTags.collectAsStateWithLifecycle()
    val autoDismissed by viewModel.autoDismissed.collectAsStateWithLifecycle()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var editing by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(autoDismissed) {
        if (autoDismissed && !editing) {
            sheetState.hide()
            onFinish()
        }
    }

    ModalBottomSheet(onDismissRequest = onFinish, sheetState = sheetState) {
        Column(
            Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 24.dp, vertical = 8.dp)
                .pointerInput(Unit) {
                    awaitPointerEventScope {
                        while (true) {
                            val event = awaitPointerEvent(PointerEventPass.Initial)
                            if (event.changes.any { it.pressed }) viewModel.onInteraction()
                        }
                    }
                },
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            when (val s = state) {
                SaveState.Saving -> LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical = 24.dp))
                is SaveState.Saved -> {
                    val it = item
                    if (s.alreadySaved) {
                        AlreadySaved(it, onClose = { closeSheet(scope, sheetState, onFinish) }, onContinue = { onOpenApp(s.itemId) })
                    } else {
                        JustSaved(
                            item = it,
                            onAddTags = { editing = true },
                            onFavourite = viewModel::toggleFavorite,
                            onOpen = { onOpenApp(s.itemId) },
                            onDone = { closeSheet(scope, sheetState, onFinish) },
                        )
                    }
                    if (editing) {
                        EditTagsSheet(
                            initialTags = it?.tags.orEmpty(),
                            suggestions = recentTags,
                            onSave = { names ->
                                scope.launch {
                                    viewModel.setTags(s.itemId, names)
                                    editing = false
                                }
                            },
                            onDismiss = { editing = false },
                        )
                    }
                }
                SaveState.NoUrl -> Header(
                    icon = Icons.Rounded.LinkOff,
                    circle = MaterialTheme.colorScheme.surfaceContainerHighest,
                    iconTint = MaterialTheme.colorScheme.onSurface,
                    title = stringResource(R.string.feature_library_share_no_url),
                    sub = null,
                )
                SaveState.NeedsSignIn -> {
                    Header(
                        icon = Icons.Rounded.BookmarkAdded,
                        circle = MaterialTheme.colorScheme.surfaceContainerHighest,
                        iconTint = MaterialTheme.colorScheme.onSurface,
                        title = stringResource(R.string.feature_library_share_sign_in_needed),
                        sub = null,
                    )
                    Button(onClick = onSignIn, modifier = Modifier.align(Alignment.End)) {
                        Text(stringResource(R.string.feature_library_sign_in))
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
private fun closeSheet(scope: kotlinx.coroutines.CoroutineScope, sheetState: SheetState, onFinish: () -> Unit) {
    scope.launch {
        sheetState.hide()
        onFinish()
    }
}

@Composable
private fun JustSaved(
    item: Item?,
    onAddTags: () -> Unit,
    onFavourite: () -> Unit,
    onOpen: () -> Unit,
    onDone: () -> Unit,
) {
    val downloaded = item?.offline == OfflineState.DOWNLOADED
    Header(
        icon = Icons.Rounded.Check,
        circle = MaterialTheme.srokaColors.brand,
        iconTint = MaterialTheme.srokaColors.onBrand,
        title = stringResource(R.string.feature_library_share_saved),
        sub = stringResource(
            if (downloaded) R.string.feature_library_share_sub_saved else R.string.feature_library_share_sub_downloading,
        ),
    )
    if (item != null) {
        ItemCard(item) {
            val minutes = item.readingMinutes
            Text(
                if (minutes != null) {
                    stringResource(R.string.feature_library_share_card_meta, item.domain, minutes)
                } else {
                    item.domain
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        AssistChip(
            onClick = onAddTags,
            label = { Text(stringResource(R.string.feature_library_share_add_tags)) },
            leadingIcon = {
                Icon(Icons.Rounded.NewLabel, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            },
            shape = RoundedCornerShape(8.dp),
            enabled = item != null,
        )
        val fav = item?.isFavorite == true
        FilterChip(
            selected = fav,
            onClick = onFavourite,
            label = { Text(stringResource(R.string.feature_library_share_favourite)) },
            leadingIcon = {
                Icon(
                    if (fav) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                    contentDescription = null,
                    tint = if (fav) MaterialTheme.srokaColors.progress else MaterialTheme.colorScheme.primary,
                )
            },
            shape = RoundedCornerShape(8.dp),
            enabled = item != null,
            colors = FilterChipDefaults.filterChipColors(),
        )
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
        TextButton(onClick = onOpen) { Text(stringResource(R.string.feature_library_share_open)) }
        Button(onClick = onDone) { Text(stringResource(R.string.feature_library_share_done)) }
    }
}

@Composable
private fun AlreadySaved(item: Item?, onClose: () -> Unit, onContinue: () -> Unit) {
    val inArchive = item?.status == ItemStatus.ARCHIVED
    val date = item?.let {
        DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).format(Instant.ofEpochMilli(it.savedAt).atZone(ZoneId.systemDefault()))
    }.orEmpty()
    Header(
        icon = Icons.Rounded.BookmarkAdded,
        circle = MaterialTheme.colorScheme.surfaceContainerHighest,
        iconTint = MaterialTheme.colorScheme.onSurface,
        title = stringResource(R.string.feature_library_share_already_title),
        sub = if (item == null) {
            null
        } else {
            stringResource(
                if (inArchive) R.string.feature_library_share_already_in_archive else R.string.feature_library_share_already_in_list,
                date,
            )
        },
    )
    if (item != null) {
        val rp = readProgressOf(item)
        ItemCard(item) {
            Text(
                if (rp.minutesLeft != null) {
                    stringResource(R.string.feature_library_share_progress, rp.percent, rp.minutesLeft)
                } else {
                    "${rp.percent}%"
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Box(
                Modifier
                    .padding(top = 4.dp)
                    .fillMaxWidth()
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainerHighest),
            ) {
                Box(
                    Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(item.progress.coerceIn(0f, 1f))
                        .background(MaterialTheme.srokaColors.progress),
                )
            }
        }
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
        TextButton(onClick = onClose) { Text(stringResource(R.string.feature_library_share_close)) }
        Button(onClick = onContinue) { Text(stringResource(R.string.feature_library_share_continue)) }
    }
}

@Composable
private fun Header(icon: ImageVector, circle: Color, iconTint: Color, title: String, sub: String?) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(circle), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = iconTint)
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.titleLarge)
            if (sub != null) {
                Text(sub, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** Outlined 12dp card: thumbnail, title and [extra] lines. */
@Composable
private fun ItemCard(item: Item, extra: @Composable ColumnScope.() -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(12.dp))
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Thumbnail(item.thumbnailPath)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                item.displayTitle,
                style = MaterialTheme.typography.titleMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            extra()
        }
    }
}

@Composable
private fun Thumbnail(path: String?) {
    val shape = RoundedCornerShape(8.dp)
    val container = MaterialTheme.colorScheme.primaryContainer
    val stripe = MaterialTheme.colorScheme.surfaceContainerHighest
    val modifier = Modifier.size(56.dp).clip(shape)
    if (path != null) {
        AsyncImage(
            model = File(path),
            contentDescription = stringResource(R.string.feature_library_share_thumbnail),
            contentScale = ContentScale.Crop,
            modifier = modifier,
        )
    } else {
        Box(
            modifier.background(
                Brush.linearGradient(
                    0f to container, 0.5f to container, 0.5f to stripe, 1f to stripe,
                    start = androidx.compose.ui.geometry.Offset.Zero,
                    end = androidx.compose.ui.geometry.Offset(24f, 24f),
                    tileMode = TileMode.Repeated,
                ),
            ),
        )
    }
}
