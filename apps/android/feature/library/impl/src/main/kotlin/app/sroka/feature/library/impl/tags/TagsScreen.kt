package app.sroka.feature.library.impl.tags

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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Label
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Search
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
import kotlinx.coroutines.launch

/**
 * The Tags tab (screen 12): large top app bar with a search action (filters the tag list in place)
 * and the avatar (opens Settings via [onOpenSettings]); rows show `label` icon, name and article
 * count. Tap opens the tag's items, long-press offers rename / delete.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TagsRoute(
    onOpenTag: (String) -> Unit,
    onOpenSettings: () -> Unit,
    viewModel: TagsViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val avatar by viewModel.avatarLetter.collectAsStateWithLifecycle()
    var renaming by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf<String?>(null) }
    var searching by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()

    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = { Text(stringResource(R.string.feature_library_tags)) },
                scrollBehavior = scrollBehavior,
                actions = {
                    IconButton(onClick = {
                        searching = !searching
                        if (!searching) query = ""
                    }) {
                        Icon(
                            if (searching) Icons.Rounded.Close else Icons.Rounded.Search,
                            contentDescription = stringResource(
                                if (searching) R.string.feature_library_tags_search_close else R.string.feature_library_tags_search,
                            ),
                        )
                    }
                    Avatar(avatar, onOpenSettings)
                },
            )
        },
    ) { padding ->
        val tags = state.tags
        val shown = if (query.isBlank()) tags else tags?.filter { tagKey(it.name).contains(tagKey(query)) }
        when {
            tags == null -> Box(Modifier.padding(padding).fillMaxSize())
            tags.isEmpty() -> SrokaEmptyState(
                icon = Icons.AutoMirrored.Rounded.Label,
                title = stringResource(R.string.feature_library_empty_tags_title),
                description = stringResource(R.string.feature_library_empty_tags_body),
                modifier = Modifier.padding(padding),
            )
            else -> Box(Modifier.padding(padding).fillMaxSize()) {
                LazyColumn(Modifier.fillMaxSize()) {
                    if (searching) {
                        item(key = "search", contentType = "search") {
                            OutlinedTextField(
                                value = query,
                                onValueChange = { query = it },
                                singleLine = true,
                                placeholder = { Text(stringResource(R.string.feature_library_tags_search)) },
                                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                            )
                        }
                    }
                    if (shown.isNullOrEmpty()) {
                        item(key = "none", contentType = "none") {
                            Text(
                                stringResource(R.string.feature_library_tags_no_match),
                                style = MaterialTheme.typography.bodyLarge,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(24.dp),
                            )
                        }
                    }
                    items(shown.orEmpty(), key = { it.name }, contentType = { "tag" }) { tag ->
                        TagRow(
                            tag = tag,
                            onClick = { onOpenTag(tag.name) },
                            onRename = { renaming = tag.name },
                            onDelete = { deleting = tag.name },
                        )
                    }
                }
            }
        }
    }

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

@Composable
private fun Avatar(letter: String?, onClick: () -> Unit) {
    Box(
        Modifier
            .padding(start = 4.dp, end = 12.dp)
            .size(32.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.primaryContainer)
            .clickable(role = Role.Button, onClickLabel = stringResource(R.string.feature_library_settings), onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            letter.orEmpty(),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onPrimaryContainer,
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TagRow(tag: TagCount, onClick: () -> Unit, onRename: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val haptic = LocalHapticFeedback.current
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .height(56.dp)
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = {
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        menu = true
                    },
                    onLongClickLabel = stringResource(R.string.feature_library_tags_more),
                )
                .padding(start = 16.dp, end = 24.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(16.dp),
        ) {
            Icon(Icons.AutoMirrored.Rounded.Label, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(tag.name, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f), maxLines = 1)
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
