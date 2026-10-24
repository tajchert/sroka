package app.sroka.feature.reader.impl.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.UserPreferences
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
