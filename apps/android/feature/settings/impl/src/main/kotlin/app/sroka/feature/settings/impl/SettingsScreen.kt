package app.sroka.feature.settings.impl

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.core.model.DownloadPolicy
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.ThemeMode
import app.sroka.core.model.UserPreferences

const val DELETE_CONFIRMATION_WORD = "DELETE"

private enum class Dialog { None, RemoveDownloads, SignOut, DeleteAccount, Server }

@Composable
fun SettingsRoute(onBack: () -> Unit, viewModel: SettingsViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.messages.collect { msg ->
            snackbar.showSnackbar(
                context.getString(
                    when (msg) {
                        SettingsMessage.FetchStarted -> R.string.feature_settings_fetch_started
                        SettingsMessage.DownloadsRemoved -> R.string.feature_settings_downloads_removed
                        SettingsMessage.DeleteFailed -> R.string.feature_settings_delete_failed
                        SettingsMessage.ServerSaved -> R.string.feature_settings_server_saved
                    },
                ),
            )
        }
    }
    SettingsScreen(state, viewModel, snackbar, onBack)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    state: SettingsUiState,
    vm: SettingsViewModel,
    snackbar: SnackbarHostState,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    var dialog by rememberSaveable { mutableStateOf(Dialog.None) }
    val prefs = state.preferences

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.feature_settings_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.feature_settings_back))
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Column(Modifier.padding(padding).verticalScroll(rememberScrollState())) {
            SectionHeader(R.string.feature_settings_section_downloads)
            DownloadPolicy.entries.forEach { policy ->
                RadioRow(
                    label = stringResource(policy.labelRes()),
                    selected = prefs.downloadPolicy == policy,
                    onClick = { vm.setDownloadPolicy(policy) },
                )
            }
            ListItem(
                headlineContent = { Text(stringResource(R.string.feature_settings_download_all)) },
                supportingContent = { Text(stringResource(R.string.feature_settings_download_all_hint)) },
                modifier = Modifier.clickable { vm.downloadAllNow() },
            )
            ListItem(
                headlineContent = { Text(stringResource(R.string.feature_settings_storage_used)) },
                supportingContent = { Text(Formatter.formatFileSize(context, state.storageBytes)) },
            )
            ListItem(
                headlineContent = { Text(stringResource(R.string.feature_settings_remove_downloads)) },
                modifier = Modifier.clickable { dialog = Dialog.RemoveDownloads },
            )
            HorizontalDivider()

            SectionHeader(R.string.feature_settings_section_reading)
            LabeledSegments(
                label = R.string.feature_settings_theme,
                options = ThemeMode.entries,
                selected = prefs.themeMode,
                labelOf = { stringResource(it.labelRes()) },
                onSelect = vm::setThemeMode,
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                ListItem(
                    headlineContent = { Text(stringResource(R.string.feature_settings_dynamic_color)) },
                    supportingContent = { Text(stringResource(R.string.feature_settings_dynamic_color_hint)) },
                    trailingContent = { Switch(checked = prefs.dynamicColor, onCheckedChange = null) },
                    modifier = Modifier.toggleable(
                        value = prefs.dynamicColor,
                        role = Role.Switch,
                        onValueChange = vm::setDynamicColor,
                    ),
                )
            }
            LabeledSegments(
                label = R.string.feature_settings_reader_theme,
                options = ReaderTheme.entries,
                selected = prefs.readerTheme,
                labelOf = { stringResource(it.labelRes()) },
                onSelect = vm::setReaderTheme,
            )
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                Text(stringResource(R.string.feature_settings_text_size), style = MaterialTheme.typography.bodyLarge)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("A", style = MaterialTheme.typography.bodySmall)
                    Slider(
                        value = prefs.readerTextScale,
                        onValueChange = vm::setReaderTextScale,
                        valueRange = UserPreferences.READER_TEXT_SCALE_MIN..UserPreferences.READER_TEXT_SCALE_MAX,
                        modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
                    )
                    Text("A", style = MaterialTheme.typography.headlineSmall)
                }
            }
            HorizontalDivider()

            SectionHeader(R.string.feature_settings_section_account)
            ListItem(
                headlineContent = { Text(state.email ?: stringResource(R.string.feature_settings_signed_out)) },
                supportingContent = { Text(stringResource(R.string.feature_settings_signed_in_as)) },
            )
            ListItem(
                headlineContent = { Text(stringResource(R.string.feature_settings_sign_out)) },
                modifier = Modifier.clickable(enabled = !state.busy) { dialog = Dialog.SignOut },
            )
            ListItem(
                headlineContent = {
                    Text(stringResource(R.string.feature_settings_delete_account), color = MaterialTheme.colorScheme.error)
                },
                trailingContent = { if (state.busy) CircularProgressIndicator(Modifier.size(24.dp)) },
                modifier = Modifier.clickable(enabled = !state.busy) { dialog = Dialog.DeleteAccount },
            )
            HorizontalDivider()

            SectionHeader(R.string.feature_settings_section_data)
            ListItem(
                headlineContent = { Text(stringResource(R.string.feature_settings_import_export)) },
                supportingContent = { Text(stringResource(R.string.feature_settings_import_export_hint)) },
                modifier = Modifier.clickable { openWebApp(context, state.serverUrl) },
            )
            HorizontalDivider()

            SectionHeader(R.string.feature_settings_section_advanced)
            ListItem(
                headlineContent = { Text(stringResource(R.string.feature_settings_server)) },
                supportingContent = { Text(state.serverUrl) },
                modifier = Modifier.clickable {
                    vm.clearServerError()
                    dialog = Dialog.Server
                },
            )
            HorizontalDivider()

            SectionHeader(R.string.feature_settings_section_about)
            ListItem(
                headlineContent = { Text(stringResource(R.string.feature_settings_version)) },
                supportingContent = { Text(appVersion(context)) },
            )
            Spacer(Modifier.height(24.dp))
        }
    }

    val close = { dialog = Dialog.None }
    when (dialog) {
        Dialog.None -> Unit
        Dialog.RemoveDownloads -> ConfirmDialog(
            title = R.string.feature_settings_remove_downloads,
            body = stringResource(R.string.feature_settings_remove_downloads_body),
            confirm = R.string.feature_settings_remove,
            onConfirm = { vm.removeDownloads(); close() },
            onDismiss = close,
        )
        Dialog.SignOut -> ConfirmDialog(
            title = R.string.feature_settings_sign_out,
            body = stringResource(R.string.feature_settings_sign_out_body),
            confirm = R.string.feature_settings_sign_out,
            onConfirm = { vm.signOut(); close() },
            onDismiss = close,
        )
        Dialog.DeleteAccount -> DeleteAccountDialog(
            onConfirm = { vm.deleteAccount(); close() },
            onDismiss = close,
        )
        Dialog.Server -> ServerDialog(
            initial = state.serverUrl,
            invalid = state.serverUrlInvalid,
            onSave = { vm.saveServerUrl(it, onDone = close) },
            onDismiss = close,
        )
    }
}

@Composable
private fun SectionHeader(res: Int) {
    Text(
        stringResource(res),
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun RadioRow(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null)
        Spacer(Modifier.width(16.dp))
        Text(label, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun <T> LabeledSegments(
    label: Int,
    options: List<T>,
    selected: T,
    labelOf: @Composable (T) -> String,
    onSelect: (T) -> Unit,
) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(label), style = MaterialTheme.typography.bodyLarge)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            options.forEachIndexed { index, option ->
                SegmentedButton(
                    selected = option == selected,
                    onClick = { onSelect(option) },
                    shape = SegmentedButtonDefaults.itemShape(index, options.size),
                ) { Text(labelOf(option), maxLines = 1) }
            }
        }
    }
}

@Composable
private fun ConfirmDialog(
    title: Int,
    body: String,
    confirm: Int,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(title)) },
        text = { Text(body) },
        confirmButton = { TextButton(onClick = onConfirm) { Text(stringResource(confirm)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_settings_cancel)) } },
    )
}

@Composable
private fun DeleteAccountDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    var typed by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.feature_settings_delete_account)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.feature_settings_delete_account_body))
                OutlinedTextField(
                    value = typed,
                    onValueChange = { typed = it },
                    singleLine = true,
                    label = { Text(stringResource(R.string.feature_settings_delete_type, DELETE_CONFIRMATION_WORD)) },
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm, enabled = typed.trim() == DELETE_CONFIRMATION_WORD) {
                Text(stringResource(R.string.feature_settings_delete_forever), color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_settings_cancel)) } },
    )
}

@Composable
private fun ServerDialog(initial: String, invalid: Boolean, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var value by rememberSaveable { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.feature_settings_server)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.feature_settings_server_body))
                OutlinedTextField(
                    value = value,
                    onValueChange = { value = it },
                    singleLine = true,
                    isError = invalid,
                    label = { Text(stringResource(R.string.feature_settings_server_label)) },
                    supportingText = { if (invalid) Text(stringResource(R.string.feature_settings_server_invalid)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { onSave(value) }),
                )
            }
        },
        confirmButton = { TextButton(onClick = { onSave(value) }) { Text(stringResource(R.string.feature_settings_save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_settings_cancel)) } },
    )
}

private fun DownloadPolicy.labelRes() = when (this) {
    DownloadPolicy.WIFI_ONLY -> R.string.feature_settings_policy_wifi
    DownloadPolicy.ANY_NETWORK -> R.string.feature_settings_policy_any
    DownloadPolicy.MANUAL -> R.string.feature_settings_policy_manual
}

private fun ThemeMode.labelRes() = when (this) {
    ThemeMode.SYSTEM -> R.string.feature_settings_theme_system
    ThemeMode.LIGHT -> R.string.feature_settings_theme_light
    ThemeMode.DARK -> R.string.feature_settings_theme_dark
}

private fun ReaderTheme.labelRes() = when (this) {
    ReaderTheme.AUTO -> R.string.feature_settings_reader_auto
    ReaderTheme.LIGHT -> R.string.feature_settings_reader_light
    ReaderTheme.SEPIA -> R.string.feature_settings_reader_sepia
    ReaderTheme.DARK -> R.string.feature_settings_reader_dark
}

private fun appVersion(context: Context): String = runCatching {
    context.packageManager.getPackageInfo(context.packageName, 0).versionName
}.getOrNull() ?: "-"

/** Opens `<server>/app/` (import/export live in the web app). */
private fun openWebApp(context: Context, serverUrl: String) {
    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(serverUrl.trimEnd('/') + "/app/"))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    try {
        context.startActivity(intent)
    } catch (_: ActivityNotFoundException) {
        // No browser available; nothing sensible to do.
    }
}
