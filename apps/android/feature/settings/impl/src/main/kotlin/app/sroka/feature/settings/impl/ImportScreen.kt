package app.sroka.feature.settings.impl

import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.FolderZip
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.core.domain.ImportError
import app.sroka.core.model.ImportJob
import app.sroka.core.model.JobStatus
import app.sroka.core.ui.rememberWithNotificationPermission
import java.text.NumberFormat

@Composable
fun ImportRoute(onBack: () -> Unit, viewModel: ImportViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    ImportScreen(
        state = state,
        onBack = onBack,
        onSource = viewModel::selectSource,
        onPicked = viewModel::onFilePicked,
        onImport = viewModel::startImport,
        onDone = viewModel::dismiss,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImportScreen(
    state: ImportUiState,
    onBack: () -> Unit,
    onSource: (ImportSource) -> Unit,
    onPicked: (String?) -> Unit,
    onImport: () -> Unit,
    onDone: () -> Unit,
) {
    val context = LocalContext.current
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        onPicked(uri?.toString())
    }
    val pick = { picker.launch(importMimeTypes(state.source)) }
    val startImport = rememberWithNotificationPermission(onImport)
    val job = state.job

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.feature_settings_import_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.feature_settings_back))
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).verticalScroll(rememberScrollState())) {
            Text(
                stringResource(R.string.feature_settings_import_intro),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 24.dp, end = 24.dp, bottom = 8.dp),
            )
            GroupLabel(stringResource(R.string.feature_settings_import_source))
            Column(Modifier.selectableGroup()) {
                ImportSource.entries.forEach { source ->
                    RadioOptionRow(
                        title = stringResource(source.labelRes()),
                        selected = state.source == source,
                        onClick = { onSource(source) },
                        enabled = !state.jobRunning && !state.uploading,
                    )
                }
            }

            FileCard(state, context, onClick = pick)

            state.error?.let {
                Text(
                    stringResource(it.messageRes()),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp),
                )
            }

            Button(
                onClick = startImport,
                enabled = state.canImport,
                modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 16.dp),
            ) {
                if (state.uploading) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Text(
                        stringResource(R.string.feature_settings_import_uploading),
                        modifier = Modifier.padding(start = 8.dp),
                    )
                } else {
                    Text(stringResource(R.string.feature_settings_import_button))
                }
            }

            if (job != null) JobCard(job, onDone)
        }
    }
}

@Composable
private fun FileCard(state: ImportUiState, context: android.content.Context, onClick: () -> Unit) {
    val enabled = !state.jobRunning && !state.uploading
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp),
    ) {
        Row(
            Modifier.padding(start = 16.dp, top = 12.dp, bottom = 12.dp, end = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            val name = state.fileName
            val isZip = name?.endsWith(".zip", ignoreCase = true) == true
            Icon(
                if (isZip) Icons.Rounded.FolderZip else Icons.Rounded.Description,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    name ?: stringResource(R.string.feature_settings_import_choose_file),
                    style = MaterialTheme.typography.bodyLarge,
                    maxLines = 1,
                )
                state.fileSizeBytes?.let {
                    Text(
                        Formatter.formatShortFileSize(context, it),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (name != null) {
                TextButton(onClick = onClick, enabled = enabled) {
                    Text(stringResource(R.string.feature_settings_import_change))
                }
            }
        }
    }
}

@Composable
private fun JobCard(job: ImportJob, onDone: () -> Unit) {
    val numbers = NumberFormat.getIntegerInstance()
    Surface(
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 24.dp),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            when (job.status) {
                JobStatus.QUEUED, JobStatus.RUNNING -> {
                    val total = job.total
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(
                            stringResource(R.string.feature_settings_import_importing),
                            style = MaterialTheme.typography.labelLarge,
                        )
                        Text(
                            if (total != null) {
                                stringResource(
                                    R.string.feature_settings_import_progress,
                                    numbers.format(job.done),
                                    numbers.format(total),
                                )
                            } else {
                                stringResource(R.string.feature_settings_import_progress_count, numbers.format(job.done))
                            },
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (total != null && total > 0) {
                        LinearProgressIndicator(
                            progress = { (job.done.toFloat() / total).coerceIn(0f, 1f) },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    } else {
                        LinearProgressIndicator(Modifier.fillMaxWidth())
                    }
                    Text(
                        stringResource(R.string.feature_settings_import_leave),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                JobStatus.DONE -> {
                    val imported = (job.done - job.skipped).coerceAtLeast(0)
                    Text(
                        pluralStringResource(
                            R.plurals.feature_settings_import_finished,
                            imported,
                            numbers.format(imported),
                        ),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    if (job.skipped > 0) {
                        Text(
                            pluralStringResource(
                                R.plurals.feature_settings_import_skipped,
                                job.skipped,
                                numbers.format(job.skipped),
                            ),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    DoneButton(onDone)
                }
                JobStatus.FAILED -> {
                    Text(
                        stringResource(R.string.feature_settings_import_failed),
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                    Text(
                        stringResource(jobErrorRes(job.error)),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    DoneButton(onDone)
                }
            }
        }
    }
}

@Composable
private fun DoneButton(onDone: () -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Button(onClick = onDone) { Text(stringResource(R.string.feature_settings_import_done)) }
    }
}

private fun ImportSource.labelRes() = when (this) {
    ImportSource.POCKET -> R.string.feature_settings_import_source_pocket
    ImportSource.INSTAPAPER -> R.string.feature_settings_import_source_instapaper
    ImportSource.BROWSER -> R.string.feature_settings_import_source_browser
}

internal fun ImportError.messageRes() = when (this) {
    ImportError.TOO_LARGE -> R.string.feature_settings_import_err_too_large
    ImportError.RATE_LIMITED -> R.string.feature_settings_import_err_rate_limited
    ImportError.BAD_FILE -> R.string.feature_settings_import_err_bad_file
    ImportError.UNAVAILABLE -> R.string.feature_settings_import_err_unavailable
    ImportError.NETWORK -> R.string.feature_settings_import_err_network
    ImportError.SIGNED_OUT -> R.string.feature_settings_import_err_signed_out
    ImportError.UNKNOWN -> R.string.feature_settings_import_err_unknown
}

/** Server job error codes (api.md §11.1) to copy; unknown codes get the generic message. */
internal fun jobErrorRes(code: String?) = when (code) {
    "too_many_rows" -> R.string.feature_settings_import_job_too_many
    "zip_too_large", "bad_zip" -> R.string.feature_settings_import_job_zip
    "missing_url_column" -> R.string.feature_settings_import_job_missing_url
    "no_csv_in_zip" -> R.string.feature_settings_import_job_no_csv
    else -> R.string.feature_settings_import_job_generic
}
