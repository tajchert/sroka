package app.sroka.feature.settings.impl

import android.content.Context
import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.rounded.CloudDownload
import androidx.compose.material.icons.rounded.DarkMode
import androidx.compose.material.icons.rounded.DeleteForever
import androidx.compose.material.icons.rounded.DeleteSweep
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.DownloadForOffline
import androidx.compose.material.icons.rounded.FormatSize
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.MoveToInbox
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.UploadFile
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.ButtonDefaults
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
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
import app.sroka.core.ui.rememberWithNotificationPermission

private enum class Dialog { None, Theme, ReaderTheme, TextSize, Offline, RemoveDownloads, SignOut, DeleteAccount, Server }

@Composable
fun SettingsRoute(
    onBack: () -> Unit,
    onOpenImport: () -> Unit = {},
    onOpenExport: () -> Unit = {},
    viewModel: SettingsViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val resources = LocalResources.current
    LaunchedEffect(viewModel) {
        viewModel.messages.collect { msg ->
            snackbar.showSnackbar(
                resources.getString(
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
    SettingsScreen(state, viewModel, snackbar, onBack, onOpenImport, onOpenExport)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    state: SettingsUiState,
    vm: SettingsViewModel,
    snackbar: SnackbarHostState,
    onBack: () -> Unit,
    onOpenImport: () -> Unit,
    onOpenExport: () -> Unit,
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
                        Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.feature_settings_back))
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        val downloadAllNow = rememberWithNotificationPermission(vm::downloadAllNow)
        Column(Modifier.padding(padding).verticalScroll(rememberScrollState())) {
            SectionHeader(R.string.feature_settings_section_reading)
            SettingRow(
                Icons.Rounded.DarkMode,
                stringResource(R.string.feature_settings_theme),
                stringResource(prefs.themeMode.labelRes()),
            ) { dialog = Dialog.Theme }
            SettingRow(
                Icons.Rounded.Palette,
                stringResource(R.string.feature_settings_reader_theme),
                stringResource(prefs.readerTheme.labelRes()),
            ) { dialog = Dialog.ReaderTheme }
            SettingRow(
                Icons.Rounded.FormatSize,
                stringResource(R.string.feature_settings_text_size),
                textSizeLabel(prefs.readerTextScale),
            ) { dialog = Dialog.TextSize }

            SectionHeader(R.string.feature_settings_section_library)
            SettingRow(
                Icons.Rounded.DownloadForOffline,
                stringResource(R.string.feature_settings_offline),
                stringResource(
                    R.string.feature_settings_offline_sub,
                    stringResource(prefs.downloadPolicy.labelRes()),
                    Formatter.formatShortFileSize(context, state.storageBytes),
                ),
            ) { dialog = Dialog.Offline }
            SettingRow(
                Icons.Rounded.CloudDownload,
                stringResource(R.string.feature_settings_download_all),
                stringResource(R.string.feature_settings_download_all_hint),
                onClick = downloadAllNow,
            )
            SettingRow(
                Icons.Rounded.DeleteSweep,
                stringResource(R.string.feature_settings_remove_downloads),
                null,
            ) { dialog = Dialog.RemoveDownloads }
            SettingRow(Icons.Rounded.Dns, stringResource(R.string.feature_settings_server), state.serverUrl) {
                vm.clearServerError()
                dialog = Dialog.Server
            }
            SettingRow(
                Icons.Rounded.UploadFile,
                stringResource(R.string.feature_settings_export),
                stringResource(R.string.feature_settings_export_sub),
                onClick = onOpenExport,
            )
            SettingRow(
                Icons.Rounded.MoveToInbox,
                stringResource(R.string.feature_settings_import),
                stringResource(R.string.feature_settings_import_sub),
                onClick = onOpenImport,
            )

            SectionHeader(R.string.feature_settings_section_account)
            SettingRow(
                Icons.AutoMirrored.Rounded.Logout,
                stringResource(R.string.feature_settings_sign_out),
                state.email ?: stringResource(R.string.feature_settings_signed_out),
                enabled = !state.busy,
            ) { dialog = Dialog.SignOut }
            SettingRow(
                Icons.Rounded.DeleteForever,
                stringResource(R.string.feature_settings_delete_account),
                null,
                color = MaterialTheme.colorScheme.error,
                enabled = !state.busy,
                trailing = { if (state.busy) CircularProgressIndicator(Modifier.size(24.dp)) },
            ) { dialog = Dialog.DeleteAccount }
            SettingRow(
                Icons.Rounded.Info,
                stringResource(R.string.feature_settings_version),
                appVersion(context),
                onClick = null,
            )
            Spacer(Modifier.height(24.dp))
        }
    }

    val close = { dialog = Dialog.None }
    when (dialog) {
        Dialog.None -> Unit
        Dialog.Theme -> ChoiceDialog(
            title = R.string.feature_settings_theme,
            options = ThemeMode.entries,
            selected = prefs.themeMode,
            labelOf = { stringResource(it.labelRes()) },
            onSelect = { vm.setThemeMode(it); close() },
            onDismiss = close,
        )
        Dialog.ReaderTheme -> ChoiceDialog(
            title = R.string.feature_settings_reader_theme,
            options = ReaderTheme.entries,
            selected = prefs.readerTheme,
            labelOf = { stringResource(it.labelRes()) },
            onSelect = { vm.setReaderTheme(it); close() },
            onDismiss = close,
        )
        Dialog.TextSize -> ChoiceDialog(
            title = R.string.feature_settings_text_size,
            options = TextScaleSteps,
            selected = nearestTextScaleStep(prefs.readerTextScale),
            labelOf = { textSizeLabel(it) },
            onSelect = { vm.setReaderTextScale(it); close() },
            onDismiss = close,
        )
        Dialog.Offline -> ChoiceDialog(
            title = R.string.feature_settings_offline,
            options = DownloadPolicy.entries,
            selected = prefs.downloadPolicy,
            labelOf = { stringResource(it.labelRes()) },
            onSelect = { vm.setDownloadPolicy(it); close() },
            onDismiss = close,
        )
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
            email = state.email,
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
private fun textSizeLabel(scale: Float): String =
    if (isDefaultTextScale(scale)) {
        stringResource(R.string.feature_settings_text_size_default, textScaleSp(1.0f))
    } else {
        stringResource(R.string.feature_settings_text_size_value, textScaleSp(scale))
    }

@Composable
private fun SectionHeader(res: Int) {
    Text(
        stringResource(res),
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 56.dp, end = 16.dp, top = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun SettingRow(
    icon: ImageVector,
    title: String,
    sub: String?,
    color: Color = Color.Unspecified,
    enabled: Boolean = true,
    trailing: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)?,
) {
    val tint = if (color == Color.Unspecified) MaterialTheme.colorScheme.onSurfaceVariant else color
    ListItem(
        leadingContent = { Icon(icon, contentDescription = null, tint = tint) },
        headlineContent = { Text(title, color = color) },
        supportingContent = sub?.let { { Text(it) } },
        trailingContent = trailing,
        modifier = if (onClick != null) Modifier.clickable(enabled = enabled, onClick = onClick) else Modifier,
    )
}

@Composable
private fun <T> ChoiceDialog(
    title: Int,
    options: List<T>,
    selected: T,
    labelOf: @Composable (T) -> String,
    onSelect: (T) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(title)) },
        text = {
            Column(Modifier.selectableGroup().verticalScroll(rememberScrollState())) {
                options.forEach { option ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .selectable(selected = option == selected, role = Role.RadioButton) { onSelect(option) }
                            .padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = option == selected, onClick = null)
                        Spacer(Modifier.width(16.dp))
                        Text(labelOf(option), style = MaterialTheme.typography.bodyLarge)
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_settings_cancel)) } },
    )
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
private fun DeleteAccountDialog(email: String?, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    var typed by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = {
            Icon(Icons.Rounded.DeleteForever, contentDescription = null, tint = MaterialTheme.colorScheme.error)
        },
        title = { Text(stringResource(R.string.feature_settings_delete_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.feature_settings_delete_account_body))
                OutlinedTextField(
                    value = typed,
                    onValueChange = { typed = it },
                    singleLine = true,
                    label = { Text(stringResource(R.string.feature_settings_delete_type)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                )
            }
        },
        confirmButton = {
            val error = MaterialTheme.colorScheme.error
            TextButton(
                onClick = onConfirm,
                enabled = isDeleteConfirmed(typed, email),
                colors = ButtonDefaults.textButtonColors(contentColor = error, disabledContentColor = error.copy(alpha = 0.38f)),
            ) {
                Text(stringResource(R.string.feature_settings_delete_confirm))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_settings_cancel)) } },
    )
}

@Composable
private fun ServerDialog(initial: String, invalid: Boolean, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var value by rememberSaveable { mutableStateOf(initial) }
    // Settings is only reachable signed in, and switching servers signs out and wipes local data.
    val switching = value.isNotBlank() && value.trim().trimEnd('/') != initial.trimEnd('/')
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
                if (switching) {
                    Text(
                        stringResource(R.string.feature_settings_server_switch_warning),
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(value) }) {
                Text(
                    stringResource(
                        if (switching) R.string.feature_settings_server_switch else R.string.feature_settings_save,
                    ),
                )
            }
        },
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
