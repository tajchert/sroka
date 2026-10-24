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
import androidx.compose.material3.ListItemDefaults
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
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
import app.sroka.core.model.UserPreferences
import app.sroka.core.ui.rememberWithNotificationPermission
import app.sroka.feature.settings.api.SettingsChoiceKind

private enum class Dialog { None, Theme, ReaderTheme, TextSize, Offline, RemoveDownloads, SignOut, DeleteAccount, Server }

/** The row whose detail page is open in the detail pane (highlighted in the list). */
enum class SettingsSelection { Theme, ReaderTheme, TextSize, Offline, Server, Import, Export }

internal fun SettingsChoiceKind.toSelection() = when (this) {
    SettingsChoiceKind.Theme -> SettingsSelection.Theme
    SettingsChoiceKind.ReaderTheme -> SettingsSelection.ReaderTheme
    SettingsChoiceKind.TextSize -> SettingsSelection.TextSize
    SettingsChoiceKind.Offline -> SettingsSelection.Offline
    SettingsChoiceKind.Server -> SettingsSelection.Server
}

@Composable
fun SettingsRoute(
    onBack: () -> Unit,
    onOpenImport: () -> Unit = {},
    onOpenExport: () -> Unit = {},
    twoPane: Boolean = false,
    selected: SettingsSelection? = null,
    onOpenChoice: (SettingsChoiceKind) -> Unit = {},
    viewModel: SettingsViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    ShowMessages(viewModel, snackbar)
    SettingsScreen(
        state, SettingsActions.of(viewModel), snackbar, onBack, onOpenImport, onOpenExport,
        twoPane = twoPane, selected = selected, onOpenChoice = onOpenChoice,
    )
}

/** Shows the ViewModel's one-shot messages as snackbars. */
@Composable
internal fun ShowMessages(viewModel: SettingsViewModel, snackbar: SnackbarHostState) {
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
}

/** What the settings screen can ask for; [of] binds it to the ViewModel, tests pass no-ops. */
class SettingsActions(
    val clearServerError: () -> Unit = {},
    val setThemeMode: (ThemeMode) -> Unit = {},
    val setReaderTheme: (ReaderTheme) -> Unit = {},
    val setReaderTextScale: (Float) -> Unit = {},
    val setDownloadPolicy: (DownloadPolicy) -> Unit = {},
    val downloadAllNow: () -> Unit = {},
    val removeDownloads: () -> Unit = {},
    val signOut: () -> Unit = {},
    val deleteAccount: () -> Unit = {},
    val saveServerUrl: (String, () -> Unit) -> Unit = { _, _ -> },
) {
    companion object {
        fun of(vm: SettingsViewModel) = SettingsActions(
            clearServerError = { vm.clearServerError() },
            setThemeMode = { vm.setThemeMode(it) },
            setReaderTheme = { vm.setReaderTheme(it) },
            setReaderTextScale = { vm.setReaderTextScale(it) },
            setDownloadPolicy = { vm.setDownloadPolicy(it) },
            downloadAllNow = { vm.downloadAllNow() },
            removeDownloads = { vm.removeDownloads() },
            signOut = { vm.signOut() },
            deleteAccount = { vm.deleteAccount() },
            saveServerUrl = { url, done -> vm.saveServerUrl(url, done) },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    state: SettingsUiState,
    vm: SettingsActions,
    snackbar: SnackbarHostState,
    onBack: () -> Unit,
    onOpenImport: () -> Unit,
    onOpenExport: () -> Unit,
    twoPane: Boolean = false,
    selected: SettingsSelection? = null,
    onOpenChoice: (SettingsChoiceKind) -> Unit = {},
) {
    val context = LocalContext.current
    var dialog by rememberSaveable { mutableStateOf(Dialog.None) }
    val prefs = state.preferences
    // Two-pane: the single-choice settings open as detail pages instead of dialogs.
    val open = { d: Dialog, kind: SettingsChoiceKind -> if (twoPane) onOpenChoice(kind) else dialog = d }

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
        val downloadAllNow = rememberWithNotificationPermission(vm.downloadAllNow)
        // Two-pane: every row is inset the same, so the rounded highlight of the open row lines up with the rest (R13).
        Column(Modifier.padding(padding).padding(horizontal = if (twoPane) 8.dp else 0.dp).verticalScroll(rememberScrollState())) {
            SectionHeader(R.string.feature_settings_section_reading)
            SettingRow(
                Icons.Rounded.DarkMode,
                stringResource(R.string.feature_settings_theme),
                stringResource(prefs.themeMode.labelRes()),
                selected = selected == SettingsSelection.Theme,
            ) { open(Dialog.Theme, SettingsChoiceKind.Theme) }
            SettingRow(
                Icons.Rounded.Palette,
                stringResource(R.string.feature_settings_reader_theme),
                stringResource(prefs.readerTheme.labelRes()),
                selected = selected == SettingsSelection.ReaderTheme,
            ) { open(Dialog.ReaderTheme, SettingsChoiceKind.ReaderTheme) }
            SettingRow(
                Icons.Rounded.FormatSize,
                stringResource(R.string.feature_settings_text_size),
                textSizeLabel(prefs.readerTextScale),
                selected = selected == SettingsSelection.TextSize,
            ) { open(Dialog.TextSize, SettingsChoiceKind.TextSize) }

            SectionHeader(R.string.feature_settings_section_library)
            SettingRow(
                Icons.Rounded.DownloadForOffline,
                stringResource(R.string.feature_settings_offline),
                stringResource(
                    R.string.feature_settings_offline_sub,
                    stringResource(prefs.downloadPolicy.labelRes()),
                    Formatter.formatShortFileSize(context, state.storageBytes),
                ),
                selected = selected == SettingsSelection.Offline,
            ) { open(Dialog.Offline, SettingsChoiceKind.Offline) }
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
            SettingRow(
                Icons.Rounded.Dns,
                stringResource(R.string.feature_settings_server),
                state.serverUrl,
                selected = selected == SettingsSelection.Server,
            ) {
                vm.clearServerError()
                open(Dialog.Server, SettingsChoiceKind.Server)
            }
            SettingRow(
                Icons.Rounded.UploadFile,
                stringResource(R.string.feature_settings_export),
                stringResource(R.string.feature_settings_export_sub),
                selected = selected == SettingsSelection.Export,
                onClick = onOpenExport,
            )
            SettingRow(
                Icons.Rounded.MoveToInbox,
                stringResource(R.string.feature_settings_import),
                stringResource(R.string.feature_settings_import_sub),
                selected = selected == SettingsSelection.Import,
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
        Dialog.Theme -> ChoiceDialog(SettingsChoiceKind.Theme, prefs, vm, close)
        Dialog.ReaderTheme -> ChoiceDialog(SettingsChoiceKind.ReaderTheme, prefs, vm, close)
        Dialog.TextSize -> ChoiceDialog(SettingsChoiceKind.TextSize, prefs, vm, close)
        Dialog.Offline -> ChoiceDialog(SettingsChoiceKind.Offline, prefs, vm, close)
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
            onSave = { vm.saveServerUrl(it, close) },
            onDismiss = close,
        )
    }
}

@Composable
internal fun textSizeLabel(scale: Float): String =
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
    selected: Boolean = false,
    onClick: (() -> Unit)?,
) {
    val tint = if (color == Color.Unspecified) MaterialTheme.colorScheme.onSurfaceVariant else color
    ListItem(
        colors = ListItemDefaults.colors(
            containerColor = if (selected) MaterialTheme.colorScheme.primaryContainer else ListItemDefaults.containerColor,
        ),
        leadingContent = { Icon(icon, contentDescription = null, tint = tint) },
        headlineContent = { Text(title, color = color) },
        supportingContent = sub?.let { { Text(it) } },
        trailingContent = trailing,
        modifier = (if (selected) Modifier.clip(RoundedCornerShape(16.dp)) else Modifier)
            .then(if (onClick != null) Modifier.clickable(enabled = enabled, onClick = onClick) else Modifier),
    )
}

@Composable
private fun ChoiceDialog(kind: SettingsChoiceKind, prefs: UserPreferences, vm: SettingsActions, onClose: () -> Unit) {
    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(stringResource(kind.titleRes())) },
        text = { SettingsChoiceBody(kind, prefs, vm, inPane = false, onChosen = onClose) },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onClose) { Text(stringResource(R.string.feature_settings_cancel)) } },
    )
}

internal fun SettingsChoiceKind.titleRes() = when (this) {
    SettingsChoiceKind.Theme -> R.string.feature_settings_theme
    SettingsChoiceKind.ReaderTheme -> R.string.feature_settings_reader_theme
    SettingsChoiceKind.TextSize -> R.string.feature_settings_text_size
    SettingsChoiceKind.Offline -> R.string.feature_settings_offline
    SettingsChoiceKind.Server -> R.string.feature_settings_server
}

/**
 * The options of a single-choice setting, shared by the phone dialog and the detail-pane page so
 * both offer the same options with the same effects. [onChosen] runs after the choice is applied
 * (the dialog closes; the pane stays).
 */
@Composable
internal fun SettingsChoiceBody(
    kind: SettingsChoiceKind,
    prefs: UserPreferences,
    vm: SettingsActions,
    inPane: Boolean,
    onChosen: () -> Unit = {},
) {
    when (kind) {
        SettingsChoiceKind.Theme -> ChoiceList(
            ThemeMode.entries, prefs.themeMode, { stringResource(it.labelRes()) }, inPane,
        ) { vm.setThemeMode(it); onChosen() }
        SettingsChoiceKind.ReaderTheme -> ChoiceList(
            ReaderTheme.entries, prefs.readerTheme, { stringResource(it.labelRes()) }, inPane,
        ) { vm.setReaderTheme(it); onChosen() }
        SettingsChoiceKind.TextSize -> ChoiceList(
            TextScaleSteps, nearestTextScaleStep(prefs.readerTextScale), { textSizeLabel(it) }, inPane,
        ) { vm.setReaderTextScale(it); onChosen() }
        SettingsChoiceKind.Offline -> ChoiceList(
            DownloadPolicy.entries, prefs.downloadPolicy, { stringResource(it.labelRes()) }, inPane,
        ) { vm.setDownloadPolicy(it); onChosen() }
        SettingsChoiceKind.Server -> Unit
    }
}

@Composable
private fun <T> ChoiceList(
    options: List<T>,
    selected: T,
    labelOf: @Composable (T) -> String,
    inPane: Boolean,
    onSelect: (T) -> Unit,
) {
    // The pane page already scrolls; only the dialog needs its own scroll.
    Column(Modifier.selectableGroup().then(if (inPane) Modifier else Modifier.verticalScroll(rememberScrollState()))) {
        options.forEach { option ->
            if (inPane) {
                RadioOptionRow(labelOf(option), option == selected, { onSelect(option) })
            } else {
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
    val switching = isServerSwitch(value, initial)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.feature_settings_server)) },
        text = { ServerForm(value, { value = it }, switching, invalid, onSave) },
        confirmButton = { ServerSaveButton(switching) { onSave(value) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_settings_cancel)) } },
    )
}

/** The server explanation, URL field and switch warning (dialog and detail page). */
@Composable
internal fun ServerForm(
    value: String,
    onValueChange: (String) -> Unit,
    switching: Boolean,
    invalid: Boolean,
    onSave: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.feature_settings_server_body))
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
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
}

@Composable
internal fun ServerSaveButton(switching: Boolean, onClick: () -> Unit) {
    TextButton(onClick = onClick) {
        Text(
            stringResource(
                if (switching) R.string.feature_settings_server_switch else R.string.feature_settings_save,
            ),
        )
    }
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
