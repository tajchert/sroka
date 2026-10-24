package app.sroka.feature.settings.impl

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.core.domain.ExportError
import app.sroka.core.model.ExportFormat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

@Composable
fun ExportRoute(onBack: () -> Unit, detailPane: Boolean = false, viewModel: ExportViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    ExportScreen(state, onBack, viewModel::selectFormat, viewModel::export, detailPane)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExportScreen(
    state: ExportUiState,
    onBack: () -> Unit,
    onFormat: (ExportFormat) -> Unit,
    onExport: () -> Unit,
    detailPane: Boolean = false,
) {
    val context = LocalContext.current
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val ready = state.ready
    val savedMsg = stringResource(R.string.feature_settings_export_saved)
    val saveFailedMsg = stringResource(R.string.feature_settings_export_save_failed)

    val saver = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument(exportMimeType(state.format)),
    ) { uri ->
        if (uri != null && ready != null) {
            scope.launch {
                val ok = withContext(Dispatchers.IO) {
                    try {
                        context.contentResolver.openOutputStream(uri)?.use { out ->
                            File(ready.path).inputStream().use { it.copyTo(out) }
                        } != null
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        false
                    }
                }
                snackbar.showSnackbar(if (ok) savedMsg else saveFailedMsg)
            }
        }
    }

    SettingsPageScaffold(
        title = stringResource(R.string.feature_settings_export_title),
        detailPane = detailPane,
        onBack = onBack,
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Column(Modifier.padding(padding).verticalScroll(rememberScrollState())) {
            GroupLabel(stringResource(R.string.feature_settings_export_format))
            Column(Modifier.selectableGroup()) {
                ExportFormat.entries.forEach { format ->
                    RadioOptionRow(
                        title = stringResource(format.titleRes()),
                        sub = stringResource(format.subRes()),
                        selected = state.format == format,
                        onClick = { onFormat(format) },
                        minHeight = 72.dp,
                        enabled = !state.exporting,
                    )
                }
            }

            Button(
                onClick = onExport,
                enabled = !state.exporting,
                modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 16.dp),
            ) {
                if (state.exporting) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Text(
                        stringResource(R.string.feature_settings_export_building),
                        modifier = Modifier.padding(start = 8.dp),
                    )
                } else {
                    Text(stringResource(R.string.feature_settings_export_button))
                }
            }

            state.error?.let {
                Text(
                    stringResource(it.messageRes()),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp),
                )
            }

            if (ready != null) {
                Surface(
                    shape = MaterialTheme.shapes.medium,
                    color = MaterialTheme.colorScheme.surfaceContainerLow,
                    modifier = Modifier.fillMaxWidth().padding(16.dp),
                ) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                            Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(ready.fileName, style = MaterialTheme.typography.bodyLarge)
                                Text(
                                    stringResource(
                                        R.string.feature_settings_export_ready,
                                        Formatter.formatShortFileSize(context, ready.bytes),
                                    ),
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                            OutlinedButton(onClick = { shareExport(context, ready, state.format) }) {
                                Icon(Icons.Rounded.Share, contentDescription = null, modifier = Modifier.size(18.dp))
                                Text(stringResource(R.string.feature_settings_export_share), Modifier.padding(start = 8.dp))
                            }
                            Button(onClick = { saver.launch(ready.fileName) }) {
                                Icon(Icons.Rounded.Download, contentDescription = null, modifier = Modifier.size(18.dp))
                                Text(stringResource(R.string.feature_settings_export_save), Modifier.padding(start = 8.dp))
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun shareExport(context: Context, ready: ReadyExport, format: ExportFormat) {
    val uri = try {
        FileProvider.getUriForFile(context, "${context.packageName}.exports", File(ready.path))
    } catch (_: IllegalArgumentException) {
        return
    }
    val send = Intent(Intent.ACTION_SEND)
        .setType(exportMimeType(format))
        .putExtra(Intent.EXTRA_STREAM, uri)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    val chooser = Intent.createChooser(send, context.getString(R.string.feature_settings_export_share_chooser))
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    try {
        context.startActivity(chooser)
    } catch (_: ActivityNotFoundException) {
        // No app can handle the share; nothing sensible to do.
    }
}

private fun ExportFormat.titleRes() = when (this) {
    ExportFormat.CSV -> R.string.feature_settings_export_csv
    ExportFormat.JSON -> R.string.feature_settings_export_json
}

private fun ExportFormat.subRes() = when (this) {
    ExportFormat.CSV -> R.string.feature_settings_export_csv_sub
    ExportFormat.JSON -> R.string.feature_settings_export_json_sub
}

private fun ExportError.messageRes() = when (this) {
    ExportError.NETWORK -> R.string.feature_settings_export_err_network
    ExportError.SIGNED_OUT -> R.string.feature_settings_export_err_signed_out
    ExportError.SERVER -> R.string.feature_settings_export_err_server
}
