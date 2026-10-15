package app.sroka.feature.library.impl.save

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.feature.library.impl.R
import app.sroka.feature.library.impl.list.TagEditor
import app.sroka.feature.library.impl.list.addTag
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Share-target UI: a small bottom sheet "Saved to Sroka" with "Add tags" that dismisses itself after
 * ~2.5 s (not while the user edits tags). Host it in a translucent, `excludeFromRecents` activity
 * (ShareActivity) inside the app theme and pass the `ACTION_SEND` extras:
 *
 * ```
 * SaveSheetHost(
 *     sharedText = intent.getStringExtra(Intent.EXTRA_TEXT),
 *     subject = intent.getStringExtra(Intent.EXTRA_SUBJECT),
 *     onFinish = ::finish,
 *     onSignIn = { startActivity(Intent(this, MainActivity::class.java)); finish() },
 * )
 * ```
 *
 * @param onFinish the sheet is done; finish the activity
 * @param onSignIn user chose "Sign in" while signed out; open the main activity
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SaveSheetHost(
    sharedText: String?,
    subject: String?,
    onFinish: () -> Unit,
    onSignIn: () -> Unit = {},
    viewModel: SaveSheetViewModel = hiltViewModel(),
) {
    LaunchedEffect(sharedText, subject) { viewModel.start(sharedText, subject) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val recentTags by viewModel.recentTags.collectAsStateWithLifecycle()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var editing by rememberSaveable { mutableStateOf(false) }
    var tags by rememberSaveable { mutableStateOf(emptyList<String>()) }
    var draft by rememberSaveable { mutableStateOf("") }

    fun finishWithTags() {
        val saved = state as? SaveState.Saved
        scope.launch {
            if (saved != null && editing) viewModel.setTags(saved.itemId, addTag(tags, draft))
            onFinish()
        }
    }

    LaunchedEffect(state, editing) {
        val auto = state is SaveState.Saved || state is SaveState.NoUrl
        if (auto && !editing) {
            delay(AUTO_DISMISS_MS)
            onFinish()
        }
    }

    ModalBottomSheet(onDismissRequest = ::finishWithTags, sheetState = sheetState) {
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 24.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            when (val s = state) {
                SaveState.Saving -> LinearProgressIndicator(Modifier.fillMaxWidth())
                is SaveState.Saved -> {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        Text(
                            stringResource(if (s.alreadySaved) R.string.feature_library_share_already else R.string.feature_library_share_saved),
                            style = MaterialTheme.typography.titleMedium,
                        )
                    }
                    if (editing) {
                        TagEditor(tags, draft, recentTags, { tags = it }, { draft = it })
                        Button(onClick = ::finishWithTags, modifier = Modifier.align(Alignment.End)) {
                            Text(stringResource(R.string.feature_library_share_done))
                        }
                    } else {
                        TextButton(onClick = { editing = true }) {
                            Text(stringResource(R.string.feature_library_share_add_tags))
                        }
                    }
                }
                SaveState.NoUrl -> Text(
                    stringResource(R.string.feature_library_share_no_url),
                    style = MaterialTheme.typography.titleMedium,
                )
                SaveState.NeedsSignIn -> {
                    Text(
                        stringResource(R.string.feature_library_share_sign_in_needed),
                        style = MaterialTheme.typography.titleMedium,
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
