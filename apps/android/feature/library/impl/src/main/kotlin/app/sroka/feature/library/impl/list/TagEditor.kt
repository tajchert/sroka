package app.sroka.feature.library.impl.list

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.InputChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import app.sroka.core.model.MAX_TAGS_PER_ITEM
import app.sroka.core.model.MAX_TAG_LENGTH
import app.sroka.core.model.normalizeTagName
import app.sroka.core.model.tagKey
import app.sroka.feature.library.impl.R

/** Adds [raw] to [tags] (normalized, deduplicated by tag key, capped). Returns [tags] when [raw] is unusable. */
internal fun addTag(tags: List<String>, raw: String): List<String> {
    val name = normalizeTagName(raw).take(MAX_TAG_LENGTH)
    if (name.isEmpty() || tags.any { tagKey(it) == tagKey(name) } || tags.size >= MAX_TAGS_PER_ITEM) return tags
    return tags + name
}

/**
 * Chips for the current tags, a text field to add one and recent-tag suggestions.
 * [draft] is the not-yet-added text; callers merge it with [addTag] when they save.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun TagEditor(
    tags: List<String>,
    draft: String,
    suggestions: List<String>,
    onTagsChange: (List<String>) -> Unit,
    onDraftChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    fun commitDraft() {
        onTagsChange(addTag(tags, draft))
        onDraftChange("")
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (tags.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                tags.forEach { tag ->
                    InputChip(
                        selected = false,
                        onClick = { onTagsChange(tags - tag) },
                        label = { Text(tag) },
                        trailingIcon = {
                            Icon(
                                Icons.Filled.Close,
                                contentDescription = stringResource(R.string.feature_library_tags_remove, tag),
                            )
                        },
                    )
                }
            }
        }
        OutlinedTextField(
            value = draft,
            onValueChange = { onDraftChange(it.take(MAX_TAG_LENGTH)) },
            label = { Text(stringResource(R.string.feature_library_tags_input_label)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { commitDraft() }),
            trailingIcon = {
                IconButton(onClick = ::commitDraft, enabled = draft.isNotBlank()) {
                    Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.feature_library_tags_add))
                }
            },
        )
        val shown = suggestions.filter { s -> tags.none { tagKey(it) == tagKey(s) } }.take(MAX_SUGGESTIONS)
        if (shown.isNotEmpty()) {
            Text(
                stringResource(R.string.feature_library_tags_suggestions),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                shown.forEach { s ->
                    SuggestionChip(onClick = { onTagsChange(addTag(tags, s)) }, label = { Text(s) })
                }
            }
        }
    }
}

private const val MAX_SUGGESTIONS = 8

/** Dialog to edit the tags of one item. */
@Composable
internal fun EditTagsDialog(
    initialTags: List<String>,
    suggestions: List<String>,
    onSave: (List<String>) -> Unit,
    onDismiss: () -> Unit,
) {
    var tags by rememberSaveable { mutableStateOf(initialTags) }
    var draft by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.feature_library_tags_edit_title)) },
        text = { TagEditor(tags, draft, suggestions, { tags = it }, { draft = it }) },
        confirmButton = {
            TextButton(onClick = { onSave(addTag(tags, draft)) }) { Text(stringResource(R.string.feature_library_save)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_library_cancel)) }
        },
    )
}
