package app.sroka.feature.library.impl.list

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import app.sroka.core.model.extractFirstUrl
import app.sroka.feature.library.impl.R
import kotlinx.coroutines.launch

/**
 * "Add link" dialog. The field is prefilled with a URL found on the clipboard (if the user has not
 * typed yet). [onSubmit] returns false for an invalid link, which shows an inline error.
 */
@Composable
internal fun AddUrlDialog(
    onSubmit: suspend (String) -> Boolean,
    onDismiss: () -> Unit,
    onChoosePdf: (() -> Unit)? = null,
) {
    var value by rememberSaveable { mutableStateOf("") }
    var invalid by rememberSaveable { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboard.current

    LaunchedEffect(Unit) {
        val clip = try {
            clipboard.getClipEntry()?.clipData
        } catch (_: SecurityException) {
            null
        }
        val text = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
        val url = text?.let(::extractFirstUrl)
        if (url != null && value.isEmpty()) value = url
    }

    fun submit() {
        scope.launch {
            if (onSubmit(value)) onDismiss() else invalid = true
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.feature_library_add_title)) },
        text = {
          Column(verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(
                value = value,
                onValueChange = {
                    value = it
                    invalid = false
                },
                label = { Text(stringResource(R.string.feature_library_add_label)) },
                singleLine = true,
                isError = invalid,
                supportingText = if (invalid) {
                    { Text(stringResource(R.string.feature_library_add_invalid)) }
                } else {
                    null
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { submit() }),
            )
            if (onChoosePdf != null) {
                androidx.compose.material3.OutlinedButton(onClick = onChoosePdf) {
                    androidx.compose.material3.Icon(
                        app.sroka.core.designsystem.icon.SrokaIcons.UploadFile,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.feature_library_add_pdf))
                }
            }
          }
        },
        confirmButton = {
            TextButton(onClick = ::submit, enabled = value.isNotBlank()) {
                Text(stringResource(R.string.feature_library_save))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_library_cancel)) } },
    )
}

/** Confirmation before a destructive action. */
@Composable
internal fun ConfirmDialog(
    title: String,
    body: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Column(Modifier) { Text(body) } },
        confirmButton = { TextButton(onClick = onConfirm) { Text(confirmLabel) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_library_cancel)) } },
    )
}
