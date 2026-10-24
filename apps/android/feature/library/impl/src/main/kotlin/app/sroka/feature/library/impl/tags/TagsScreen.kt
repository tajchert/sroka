package app.sroka.feature.library.impl.tags

import app.sroka.core.designsystem.icon.SrokaIcons
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.core.designsystem.component.SrokaEmptyState
import app.sroka.core.model.TagCount
import app.sroka.core.model.tagKey
import app.sroka.feature.library.impl.R
import app.sroka.feature.library.impl.list.ConfirmDialog
import app.sroka.feature.library.impl.list.SearchPill
import androidx.compose.foundation.layout.Column
import kotlinx.coroutines.launch

/**
 * The Tags tab (screen 12): the My List search pill (opens full search via [onOpenSearch], avatar opens
 * Settings via [onOpenSettings]) above a large "Tags" title; rows show `label` icon, name and article
 * count. Tap opens the tag's items, long-press offers rename / delete.
 */
@Composable
fun TagsRoute(
    onOpenTag: (String) -> Unit,
    onOpenSettings: () -> Unit,
    onOpenSearch: () -> Unit = {},
    selectedTag: String? = null,
    navRailShown: Boolean = false,
    viewModel: TagsViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val avatar by viewModel.avatarLetter.collectAsStateWithLifecycle()
    var renaming by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    TagsContent(
        tags = state.tags,
        avatar = avatar,
        selectedTag = selectedTag,
        navRailShown = navRailShown,
        onOpenTag = onOpenTag,
        onOpenSettings = onOpenSettings,
        onOpenSearch = onOpenSearch,
        onRename = { renaming = it },
        onDelete = { deleting = it },
    )

    renaming?.let { name ->
        RenameTagDialog(
            name = name,
            onRename = { to ->
                scope.launch {
                    if (viewModel.rename(name, to)) renaming = null
                }
            },
            onDismiss = { renaming = null },
        )
    }
    deleting?.let { name ->
        ConfirmDialog(
            title = stringResource(R.string.feature_library_tags_delete_title, name),
            body = stringResource(R.string.feature_library_tags_delete_body),
            confirmLabel = stringResource(R.string.feature_library_tags_delete),
            onConfirm = {
                viewModel.delete(name)
                deleting = null
            },
            onDismiss = { deleting = null },
        )
    }
}

/**
 * Stateless Tags list. [selectedTag] is highlighted (two-pane); [navRailShown] hides the avatar,
 * which the rail hosts.
 */
@Composable
fun TagsContent(
    tags: List<TagCount>?,
    avatar: String?,
    selectedTag: String?,
    navRailShown: Boolean,
    onOpenTag: (String) -> Unit,
    onOpenSettings: () -> Unit,
    onRename: (String) -> Unit,
    onDelete: (String) -> Unit,
    onOpenSearch: () -> Unit = {},
) {
    Scaffold(
        topBar = {
            SearchPill(
                hint = stringResource(R.string.feature_library_search_bar_tags),
                email = avatar.orEmpty(),
                sort = null,
                onSortChange = null,
                onOpenSearch = onOpenSearch,
                onOpenSettings = onOpenSettings.takeUnless { navRailShown },
            )
        },
    ) { padding ->
        when {
            tags == null -> Box(Modifier.padding(padding).fillMaxSize())
            tags.isEmpty() -> Column(Modifier.padding(padding).fillMaxSize()) {
                TagsTitle()
                SrokaEmptyState(
                    icon = SrokaIcons.Label,
                    title = stringResource(R.string.feature_library_empty_tags_title),
                    description = stringResource(R.string.feature_library_empty_tags_body),
                )
            }
            else -> LazyColumn(Modifier.padding(padding).fillMaxSize()) {
                item(key = "title", contentType = "title") { TagsTitle() }
                items(tags, key = { it.name }, contentType = { "tag" }) { tag ->
                    TagRow(
                        tag = tag,
                        selected = tag.name == selectedTag,
                        onClick = { onOpenTag(tag.name) },
                        onRename = { onRename(tag.name) },
                        onDelete = { onDelete(tag.name) },
                    )
                }
            }
        }
    }
}

/** The large "Tags" title below the search pill. */
@Composable
private fun TagsTitle() {
    Text(
        stringResource(R.string.feature_library_tags),
        style = MaterialTheme.typography.headlineMedium,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 8.dp),
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TagRow(tag: TagCount, selected: Boolean, onClick: () -> Unit, onRename: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val haptic = LocalHapticFeedback.current
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = if (selected) 8.dp else 0.dp)
                .height(56.dp)
                .clip(if (selected) RoundedCornerShape(16.dp) else RectangleShape)
                .background(if (selected) MaterialTheme.colorScheme.primaryContainer else Color.Transparent)
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = {
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        menu = true
                    },
                    onLongClickLabel = stringResource(R.string.feature_library_tags_more),
                )
                .padding(start = if (selected) 8.dp else 16.dp, end = if (selected) 16.dp else 24.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(16.dp),
        ) {
            Icon(SrokaIcons.Label, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                tag.name,
                style = MaterialTheme.typography.bodyLarge,
                color = if (selected) MaterialTheme.colorScheme.onPrimaryContainer else Color.Unspecified,
                modifier = Modifier.weight(1f),
                maxLines = 1,
            )
            Text(
                tag.count.toString(),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.feature_library_tags_rename)) },
                onClick = {
                    menu = false
                    onRename()
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.feature_library_tags_delete)) },
                onClick = {
                    menu = false
                    onDelete()
                },
            )
        }
    }
}

@Composable
private fun RenameTagDialog(name: String, onRename: (String) -> Unit, onDismiss: () -> Unit) {
    var value by rememberSaveable { mutableStateOf(name) }
    var invalid by rememberSaveable { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.feature_library_tags_rename_title)) },
        text = {
            OutlinedTextField(
                value = value,
                onValueChange = {
                    value = it
                    invalid = false
                },
                singleLine = true,
                isError = invalid,
                supportingText = if (invalid) {
                    { Text(stringResource(R.string.feature_library_tags_rename_invalid)) }
                } else {
                    null
                },
            )
        },
        confirmButton = {
            TextButton(onClick = {
                invalid = value.isBlank() || value.length > app.sroka.core.model.MAX_TAG_LENGTH
                if (!invalid) onRename(value)
            }) { Text(stringResource(R.string.feature_library_save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_library_cancel)) } },
    )
}
