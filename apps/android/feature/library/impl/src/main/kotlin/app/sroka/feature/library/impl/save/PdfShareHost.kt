package app.sroka.feature.library.impl.save

import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.core.designsystem.icon.SrokaIcons
import app.sroka.core.designsystem.theme.srokaColors
import app.sroka.feature.library.impl.R
import app.sroka.feature.library.impl.list.uploadErrorMessage
import kotlinx.coroutines.delay

/**
 * Share-target UI for PDFs (`SEND` / `SEND_MULTIPLE` with `application/pdf`): hands [uris] to the
 * uploader and shows a short confirmation sheet; finishes itself a few seconds after queuing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PdfShareHost(
    uris: List<Uri>,
    onFinish: () -> Unit,
    onSignIn: () -> Unit = {},
    viewModel: PdfShareViewModel = hiltViewModel(),
) {
    LaunchedEffect(uris) { viewModel.start(uris) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    LaunchedEffect(state) {
        if (state is PdfShareState.Queued) {
            delay(AUTO_DISMISS_MS)
            sheetState.hide()
            onFinish()
        }
    }
    ModalBottomSheet(onDismissRequest = onFinish, sheetState = sheetState) {
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 24.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            when (val s = state) {
                PdfShareState.Working -> LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical = 24.dp))
                is PdfShareState.Queued -> Header(
                    icon = SrokaIcons.UploadFile,
                    circle = MaterialTheme.srokaColors.brand,
                    iconTint = MaterialTheme.srokaColors.onBrand,
                    title = pluralStringResource(R.plurals.feature_library_snack_pdf_queued, s.count, s.count),
                    sub = stringResource(R.string.feature_library_share_pdf_uploading_sub),
                )
                is PdfShareState.Failed -> {
                    Header(
                        icon = SrokaIcons.WarningFilled,
                        circle = MaterialTheme.colorScheme.surfaceContainerHighest,
                        iconTint = MaterialTheme.colorScheme.onSurface,
                        title = stringResource(R.string.feature_library_share_pdf_failed),
                        sub = stringResource(uploadErrorMessage(s.error)),
                    )
                    TextButton(onClick = onFinish, modifier = Modifier.align(Alignment.End)) {
                        Text(stringResource(R.string.feature_library_share_close))
                    }
                }
                PdfShareState.NoFile -> Header(
                    icon = SrokaIcons.LinkOff,
                    circle = MaterialTheme.colorScheme.surfaceContainerHighest,
                    iconTint = MaterialTheme.colorScheme.onSurface,
                    title = stringResource(R.string.feature_library_share_pdf_none),
                    sub = null,
                )
                PdfShareState.NeedsSignIn -> {
                    Header(
                        icon = SrokaIcons.BookmarkAdded,
                        circle = MaterialTheme.colorScheme.surfaceContainerHighest,
                        iconTint = MaterialTheme.colorScheme.onSurface,
                        title = stringResource(R.string.feature_library_share_sign_in_needed),
                        sub = null,
                    )
                    Button(onClick = onSignIn, modifier = Modifier.align(Alignment.End)) {
                        Text(stringResource(R.string.feature_library_sign_in))
                    }
                }
            }
        }
    }
}

private const val AUTO_DISMISS_MS = 2_500L
