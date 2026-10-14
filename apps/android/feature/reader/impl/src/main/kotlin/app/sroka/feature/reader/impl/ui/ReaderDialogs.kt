package app.sroka.feature.reader.impl.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.InputChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import app.sroka.core.model.MAX_TAGS_PER_ITEM
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.UserPreferences
import app.sroka.core.model.normalizeTagName
import app.sroka.core.model.tagKey
import app.sroka.feature.reader.impl.R

@Composable
internal fun DeleteConfirmDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.feature_reader_delete_title)) },
        text = { Text(stringResource(R.string.feature_reader_delete_message)) },
        confirmButton = { TextButton(onClick = onConfirm) { Text(stringResource(R.string.feature_reader_delete)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_reader_cancel)) } },
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun EditTagsDialog(
    current: List<String>,
    recent: List<String>,
    onSave: (List<String>) -> Unit,
    onDismiss: () -> Unit,
) {
    val tags = remember { mutableStateListOf<String>().apply { addAll(current) } }
    var input by remember { mutableStateOf("") }

    fun commit(raw: String = input) {
        val name = normalizeTagName(raw)
        if (name.isNotEmpty() && tags.size < MAX_TAGS_PER_ITEM && tags.none { tagKey(it) == tagKey(name) }) {
            tags += name
        }
        input = ""
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.feature_reader_edit_tags)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { value ->
                        if (value.endsWith(",")) commit(value.dropLast(1)) else input = value
                    },
                    label = { Text(stringResource(R.string.feature_reader_add_tag)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { commit() }),
                    modifier = Modifier.fillMaxWidth(),
                )
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    tags.toList().forEach { tag ->
                        InputChip(
                            selected = false,
                            onClick = { tags.remove(tag) },
                            label = { Text(tag) },
                            trailingIcon = {
                                Icon(
                                    Icons.Default.Close,
                                    contentDescription = stringResource(R.string.feature_reader_remove_tag, tag),
                                )
                            },
                        )
                    }
                }
                val suggestions = recent.filter { r -> tags.none { tagKey(it) == tagKey(r) } }
                if (suggestions.isNotEmpty()) {
                    Text(stringResource(R.string.feature_reader_recent_tags), style = MaterialTheme.typography.labelMedium)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        suggestions.forEach { tag ->
                            AssistChip(onClick = { commit(tag) }, label = { Text(tag) })
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                commit()
                onSave(tags.toList())
            }) { Text(stringResource(R.string.feature_reader_save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_reader_cancel)) } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AppearanceSheet(
    preferences: UserPreferences,
    onTheme: (ReaderTheme) -> Unit,
    onTextScale: (Float) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .padding(horizontal = 24.dp)
                .padding(bottom = 24.dp)
                .navigationBarsPadding(),
        ) {
            Text(stringResource(R.string.feature_reader_theme), style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(8.dp))
            val themes = ReaderTheme.entries
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                themes.forEachIndexed { index, theme ->
                    SegmentedButton(
                        selected = preferences.readerTheme == theme,
                        onClick = { onTheme(theme) },
                        shape = SegmentedButtonDefaults.itemShape(index, themes.size),
                    ) { Text(stringResource(theme.label())) }
                }
            }
            Spacer(Modifier.height(24.dp))
            Text(stringResource(R.string.feature_reader_text_size), style = MaterialTheme.typography.titleSmall)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Text("A", style = MaterialTheme.typography.bodySmall)
                Slider(
                    value = preferences.readerTextScale,
                    onValueChange = onTextScale,
                    valueRange = UserPreferences.READER_TEXT_SCALE_MIN..UserPreferences.READER_TEXT_SCALE_MAX,
                    steps = 7,
                    modifier = Modifier.weight(1f),
                )
                Text("A", style = MaterialTheme.typography.titleLarge)
            }
        }
    }
}

private fun ReaderTheme.label(): Int = when (this) {
    ReaderTheme.AUTO -> R.string.feature_reader_theme_auto
    ReaderTheme.LIGHT -> R.string.feature_reader_theme_light
    ReaderTheme.SEPIA -> R.string.feature_reader_theme_sepia
    ReaderTheme.DARK -> R.string.feature_reader_theme_dark
}
