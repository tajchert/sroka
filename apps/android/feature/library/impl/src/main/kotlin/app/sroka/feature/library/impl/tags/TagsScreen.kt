package app.sroka.feature.library.impl.tags

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.core.designsystem.component.SrokaEmptyState
import app.sroka.core.model.TagCount
import app.sroka.feature.library.impl.R
import app.sroka.feature.library.impl.list.ConfirmDialog
import kotlinx.coroutines.launch

/** The Tags tab: all tags with counts; tap opens the tag's items, the overflow menu renames or deletes. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TagsRoute(
    onOpenTag: (String) -> Unit,
    onOpenSettings: () -> Unit,
    viewModel: TagsViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    var renaming by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.feature_library_tags)) },
                actions = {
                    IconButton(onClick = onOpenSettings) {
                        Icon(Icons.Filled.Settings, contentDescription = stringResource(R.string.feature_library_settings))
                    }
                },
            )
        },
    ) { padding ->
        val tags = state.tags
        when {
            tags == null -> Box(Modifier.padding(padding).fillMaxSize())
            tags.isEmpty() -> SrokaEmptyState(
                icon = Icons.AutoMirrored.Outlined.Label,
                title = stringResource(R.string.feature_library_empty_tags_title),
                description = stringResource(R.string.feature_library_empty_tags_body),
                modifier = Modifier.padding(padding),
            )
            else -> LazyColumn(Modifier.padding(padding).fillMaxSize()) {
                items(tags, key = { it.name }, contentType = { "tag" }) { tag ->
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
private fun TagRow(tag: TagCount, onClick: () -> Unit, onRename: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text(tag.name) },
        supportingContent = { Text(pluralStringResource(R.plurals.feature_library_tag_count, tag.count, tag.count)) },
        leadingContent = { Icon(Icons.AutoMirrored.Outlined.Label, contentDescription = null) },
        trailingContent = {
            Box {
                IconButton(onClick = { menu = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.feature_library_tags_more))
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.feature_library_tags_rename)) },
                        onClick = { menu = false; onRename() },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.feature_library_tags_delete)) },
                        onClick = { menu = false; onDelete() },
                    )
                }
            }
        },
        modifier = Modifier.clickable(onClick = onClick),
    )
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
