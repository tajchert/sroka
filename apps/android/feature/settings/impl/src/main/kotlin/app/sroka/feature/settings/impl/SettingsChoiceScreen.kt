package app.sroka.feature.settings.impl

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.feature.settings.api.SettingsChoiceKind

/**
 * A single-choice setting (or the server form) as a detail-pane page, two-pane only (R14.4). Same
 * options and effects as the phone dialogs; choosing applies immediately and the page stays open.
 */
@Composable
fun SettingsChoiceRoute(kind: SettingsChoiceKind, viewModel: SettingsViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    ShowMessages(viewModel, snackbar)
    SettingsChoiceScreen(kind, state, SettingsActions.of(viewModel), snackbar)
}

@Composable
fun SettingsChoiceScreen(
    kind: SettingsChoiceKind,
    state: SettingsUiState,
    vm: SettingsActions,
    snackbar: SnackbarHostState,
) {
    SettingsPageScaffold(
        title = stringResource(kind.titleRes()),
        detailPane = true,
        onBack = {},
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Column(Modifier.padding(padding).verticalScroll(rememberScrollState())) {
            if (kind == SettingsChoiceKind.Server) {
                var value by rememberSaveable { mutableStateOf(state.serverUrl) }
                val switching = isServerSwitch(value, state.serverUrl)
                ServerForm(
                    value = value,
                    onValueChange = { value = it },
                    switching = switching,
                    invalid = state.serverUrlInvalid,
                    onSave = { vm.saveServerUrl(it) {} },
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
                )
                Box(Modifier.padding(horizontal = 16.dp)) {
                    ServerSaveButton(switching) { vm.saveServerUrl(value) {} }
                }
            } else {
                SettingsChoiceBody(kind, state.preferences, vm, inPane = true)
            }
        }
    }
}

/** Detail pane content while no settings page is open. */
@Composable
fun SettingsDetailPlaceholder() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                Icons.Rounded.Settings,
                contentDescription = null,
                modifier = Modifier.padding(bottom = 0.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                stringResource(R.string.feature_settings_choose_setting),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
