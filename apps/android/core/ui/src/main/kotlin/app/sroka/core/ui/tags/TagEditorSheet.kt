package app.sroka.core.ui.tags

import app.sroka.core.designsystem.icon.SrokaIcons
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.InputChip
import androidx.compose.material3.InputChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import app.sroka.core.model.MAX_TAGS_PER_ITEM
import app.sroka.core.model.MAX_TAG_LENGTH
import app.sroka.core.model.normalizeTagName
import app.sroka.core.model.tagKey
import app.sroka.core.ui.R
import kotlinx.coroutines.launch

/** Adds [raw] to [tags] (normalized, deduplicated by tag key, capped). Returns [tags] when [raw] is unusable. */
fun addTag(tags: List<String>, raw: String): List<String> {
    val name = normalizeTagName(raw).take(MAX_TAG_LENGTH)
    if (name.isEmpty() || tags.any { tagKey(it) == tagKey(name) } || tags.size >= MAX_TAGS_PER_ITEM) return tags
    return tags + name
}

/** Suggestion chips under the field: an optional "Create" chip, then existing tags that match the typed text. */
data class TagSuggestions(val create: String?, val existing: List<String>)

/**
 * [TagSuggestions.create] is the normalized typed text, only when it is non-empty and neither already
 * chosen in [tags] nor an exact (case-insensitive) match of a [known] tag. [TagSuggestions.existing]
 * are [known] tags not yet chosen whose name contains the typed text (prefix matches first), at most [limit].
 */
fun tagSuggestions(
    draft: String,
    tags: List<String>,
    known: List<String>,
    limit: Int = MAX_SUGGESTIONS,
): TagSuggestions {
    val typed = normalizeTagName(draft).take(MAX_TAG_LENGTH)
    val key = tagKey(typed)
    val chosen = tags.map(::tagKey).toSet()
    val candidates = known.distinctBy(::tagKey).filter { tagKey(it) !in chosen }
    val matching = if (key.isEmpty()) {
        candidates
    } else {
        candidates.filter { tagKey(it).contains(key) }.sortedBy { if (tagKey(it).startsWith(key)) 0 else 1 }
    }
    val create = typed.takeIf { it.isNotEmpty() && key !in chosen && known.none { k -> tagKey(k) == key } }
    return TagSuggestions(create, matching.take(limit))
}

/**
 * Outlined "Add a tag" field holding input chips for [tags] and the text cursor, with suggestion
 * chips underneath. [draft] is the not-yet-added text; callers merge it with [addTag] when they save.
 * [suggestions] are the known tags (recent or all) offered as chips.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun TagEditor(
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
    var focused by remember { mutableStateOf(false) }
    val focusRequester = remember { FocusRequester() }
    val outline = if (focused) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline
    val labelColor = if (focused) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
    Column(modifier, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Box(Modifier.padding(top = 8.dp)) {
            FlowRow(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 56.dp)
                    .border(BorderStroke(if (focused) 2.dp else 1.dp, outline), RoundedCornerShape(4.dp))
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                        focusRequester.requestFocus()
                    }
                    .padding(horizontal = 10.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
                itemVerticalAlignment = Alignment.CenterVertically,
            ) {
                tags.forEach { tag ->
                    InputChip(
                        selected = true,
                        onClick = { onTagsChange(tags - tag) },
                        label = { Text(tag) },
                        shape = RoundedCornerShape(8.dp),
                        trailingIcon = {
                            Icon(
                                SrokaIcons.Close,
                                contentDescription = stringResource(R.string.core_ui_tags_remove, tag),
                            )
                        },
                        colors = InputChipDefaults.inputChipColors(
                            selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                            selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer,
                            selectedTrailingIconColor = MaterialTheme.colorScheme.onPrimaryContainer,
                        ),
                        border = null,
                    )
                }
                BasicTextField(
                    value = draft,
                    onValueChange = { onDraftChange(it.take(MAX_TAG_LENGTH)) },
                    singleLine = true,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { commitDraft() }),
                    modifier = Modifier
                        .widthIn(min = 96.dp)
                        .focusRequester(focusRequester)
                        .onFocusChanged { focused = it.isFocused },
                )
            }
            Text(
                stringResource(R.string.core_ui_tags_field_label),
                style = MaterialTheme.typography.labelMedium,
                color = labelColor,
                modifier = Modifier
                    .offset(x = 10.dp, y = (-8).dp)
                    .background(MaterialTheme.colorScheme.surfaceContainerLow)
                    .padding(horizontal = 4.dp),
            )
        }
        val shown = tagSuggestions(draft, tags, suggestions)
        if (shown.create != null || shown.existing.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                shown.create?.let { name ->
                    AssistChip(
                        onClick = {
                            onTagsChange(addTag(tags, name))
                            onDraftChange("")
                        },
                        label = { Text(stringResource(R.string.core_ui_tags_create, name)) },
                        leadingIcon = { Icon(SrokaIcons.Add, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
                        shape = RoundedCornerShape(8.dp),
                    )
                }
                shown.existing.forEach { s ->
                    AssistChip(
                        onClick = {
                            onTagsChange(addTag(tags, s))
                            onDraftChange("")
                        },
                        label = { Text(s) },
                        shape = RoundedCornerShape(8.dp),
                    )
                }
            }
        }
    }
}

private const val MAX_SUGGESTIONS = 8

/**
 * Edit-tags modal bottom sheet (screen 11): "Tags" title, the [TagEditor], Cancel / Save.
 * Shared by library and reader. [suggestions] are known tags.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditTagsSheet(
    initialTags: List<String>,
    suggestions: List<String>,
    onSave: (List<String>) -> Unit,
    onDismiss: () -> Unit,
) {
    var tags by rememberSaveable { mutableStateOf(initialTags) }
    var draft by rememberSaveable { mutableStateOf("") }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier.fillMaxWidth().imePadding().navigationBarsPadding().padding(horizontal = 24.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(stringResource(R.string.core_ui_tags_sheet_title), style = MaterialTheme.typography.titleLarge)
            TagEditor(tags, draft, suggestions, { tags = it }, { draft = it })
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                TextButton(onClick = { scope.launch { sheetState.hide() }.invokeOnCompletion { onDismiss() } }) {
                    Text(stringResource(R.string.core_ui_cancel))
                }
                Button(onClick = { onSave(addTag(tags, draft)) }) { Text(stringResource(R.string.core_ui_save)) }
            }
        }
    }
}
