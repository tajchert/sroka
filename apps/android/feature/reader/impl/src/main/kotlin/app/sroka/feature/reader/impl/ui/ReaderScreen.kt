package app.sroka.feature.reader.impl.ui

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Unarchive
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Button
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import app.sroka.core.model.ItemStatus
import app.sroka.core.ui.openExternalLink
import app.sroka.feature.reader.impl.NotDownloadedReason
import app.sroka.feature.reader.impl.R
import app.sroka.feature.reader.impl.ReaderHtml
import app.sroka.feature.reader.impl.ReaderUiState
import app.sroka.feature.reader.impl.ReaderViewModel
import app.sroka.feature.reader.impl.resolveTheme

/**
 * Reader screen.
 *
 * @param onBack leave the reader
 * @param onArchived the item was archived; caller pops and shows an undo snackbar (defaults to [onBack])
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ReaderScreen(
    viewModel: ReaderViewModel,
    articlesDir: java.io.File,
    onBack: () -> Unit,
    onArchived: (itemId: String) -> Unit,
    itemId: String,
) {
    val context = LocalContext.current
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val item by viewModel.item.collectAsStateWithLifecycle()
    val prefs by viewModel.preferences.collectAsStateWithLifecycle()
    val recentTags by viewModel.recentTags.collectAsStateWithLifecycle()
    val progress by viewModel.progress.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current.lifecycle

    var leaving by remember { mutableStateOf(false) }
    val leave: () -> Unit = {
        if (!leaving) {
            leaving = true
            viewModel.flushProgress()
            onBack()
        }
    }

    // Save the reading position whenever the screen stops (also covers process death).
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) viewModel.flushProgress()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(state) {
        if (state is ReaderUiState.Missing) leave()
    }

    var menuOpen by remember { mutableStateOf(false) }
    var showTags by remember { mutableStateOf(false) }
    var showAppearance by remember { mutableStateOf(false) }
    var showDelete by remember { mutableStateOf(false) }
    val scrollBehavior = TopAppBarDefaults.enterAlwaysScrollBehavior()
    val originalUrl = item?.url

    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            TopAppBar(
                title = {
                    Text(item?.domain.orEmpty(), maxLines = 1, overflow = TextOverflow.Ellipsis)
                },
                navigationIcon = {
                    IconButton(onClick = leave) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.feature_reader_back))
                    }
                },
                actions = {
                    val current = item
                    if (current != null) {
                        IconButton(onClick = viewModel::toggleFavorite) {
                            Icon(
                                if (current.isFavorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                                stringResource(
                                    if (current.isFavorite) R.string.feature_reader_unfavorite else R.string.feature_reader_favorite,
                                ),
                            )
                        }
                        val archived = current.status == ItemStatus.ARCHIVED
                        IconButton(onClick = {
                            viewModel.flushProgress()
                            viewModel.toggleArchive { nowArchived ->
                                if (nowArchived && !leaving) {
                                    leaving = true
                                    onArchived(itemId)
                                }
                            }
                        }) {
                            Icon(
                                if (archived) Icons.Default.Unarchive else Icons.Default.Archive,
                                stringResource(if (archived) R.string.feature_reader_unarchive else R.string.feature_reader_archive),
                            )
                        }
                        IconButton(onClick = { shareUrl(context, current.url) }) {
                            Icon(Icons.Default.Share, stringResource(R.string.feature_reader_share))
                        }
                        Box {
                            IconButton(onClick = { menuOpen = true }) {
                                Icon(Icons.Default.MoreVert, stringResource(R.string.feature_reader_more))
                            }
                            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.feature_reader_open_original)) },
                                    onClick = { menuOpen = false; openExternalLink(context, current.url) },
                                )
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.feature_reader_edit_tags)) },
                                    onClick = { menuOpen = false; showTags = true },
                                )
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.feature_reader_refresh)) },
                                    onClick = { menuOpen = false; viewModel.refresh() },
                                )
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.feature_reader_appearance)) },
                                    onClick = { menuOpen = false; showAppearance = true },
                                )
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.feature_reader_delete)) },
                                    onClick = { menuOpen = false; showDelete = true },
                                )
                            }
                        }
                    }
                },
                scrollBehavior = scrollBehavior,
            )
        },
    ) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            when (val s = state) {
                is ReaderUiState.Ready -> {
                    val systemDark = MaterialTheme.colorScheme.background.luminance() < 0.5f
                    val theme = resolveTheme(prefs.readerTheme, systemDark)
                    // Wrapped once per article load; later theme/size changes go through script.
                    val wrapped = remember(s.html, s.baseUrl) {
                        val restore = viewModel.restorePoint()
                        ReaderHtml.wrap(
                            articleHtml = s.html,
                            baseUrl = s.baseUrl,
                            theme = theme,
                            textScale = prefs.readerTextScale,
                            startAnchor = restore.anchor,
                            startProgress = restore.progress,
                        )
                    }
                    var rendererGone by remember(s.html) { mutableStateOf(false) }
                    if (rendererGone) {
                        Centered {
                            Text(
                                stringResource(R.string.feature_reader_renderer_gone),
                                textAlign = TextAlign.Center,
                            )
                            OriginalButton(originalUrl) { openExternalLink(context, it) }
                        }
                    } else ArticleWebView(
                        html = wrapped,
                        baseUrl = s.baseUrl,
                        articlesDir = articlesDir,
                        theme = theme,
                        textScale = prefs.readerTextScale,
                        onProgress = viewModel::onProgress,
                        onLinkClick = { openExternalLink(context, it) },
                        onRendererGone = { rendererGone = true },
                        modifier = Modifier.fillMaxSize(),
                    )
                    LinearProgressIndicator(
                        progress = { progress },
                        modifier = Modifier
                            .fillMaxWidth()
                            .align(Alignment.TopStart),
                        drawStopIndicator = {},
                    )
                }
                ReaderUiState.Loading, ReaderUiState.Missing -> Unit
                ReaderUiState.Downloading -> Centered {
                    CircularProgressIndicator()
                    Text(stringResource(R.string.feature_reader_downloading))
                }
                is ReaderUiState.NotDownloaded -> Centered {
                    Text(
                        stringResource(R.string.feature_reader_not_downloaded_offline_title),
                        style = MaterialTheme.typography.titleMedium,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        stringResource(
                            when (s.reason) {
                                NotDownloadedReason.OFFLINE -> R.string.feature_reader_not_downloaded_offline
                                NotDownloadedReason.SIGN_IN -> R.string.feature_reader_not_downloaded_signin
                                NotDownloadedReason.ERROR -> R.string.feature_reader_not_downloaded_error
                            },
                        ),
                        textAlign = TextAlign.Center,
                    )
                    Button(onClick = viewModel::retryDownload) { Text(stringResource(R.string.feature_reader_try_again)) }
                    OriginalButton(originalUrl) { openExternalLink(context, it) }
                }
                ReaderUiState.ParsePending -> Centered {
                    Text(
                        stringResource(R.string.feature_reader_pending_title),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(stringResource(R.string.feature_reader_pending_message), textAlign = TextAlign.Center)
                    OriginalButton(originalUrl) { openExternalLink(context, it) }
                }
                is ReaderUiState.ParseFailed -> Centered {
                    Text(
                        stringResource(R.string.feature_reader_failed_title),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(stringResource(R.string.feature_reader_failed_message), textAlign = TextAlign.Center)
                    s.error?.let { Text(stringResource(R.string.feature_reader_failed_reason, it)) }
                    Button(onClick = viewModel::refresh) { Text(stringResource(R.string.feature_reader_try_again)) }
                    OriginalButton(originalUrl) { openExternalLink(context, it) }
                }
            }
        }
    }

    if (showTags) {
        EditTagsDialog(
            current = item?.tags.orEmpty(),
            recent = recentTags,
            onSave = { viewModel.setTags(it); showTags = false },
            onDismiss = { showTags = false },
        )
    }
    if (showAppearance) {
        AppearanceSheet(
            preferences = prefs,
            onTheme = viewModel::setReaderTheme,
            onTextScale = viewModel::setTextScale,
            onDismiss = { showAppearance = false },
        )
    }
    if (showDelete) {
        DeleteConfirmDialog(
            onConfirm = { showDelete = false; viewModel.delete() }, // Missing state then closes the screen
            onDismiss = { showDelete = false },
        )
    }
}

@Composable
private fun OriginalButton(url: String?, onOpen: (String) -> Unit) {
    if (url != null) {
        OutlinedButton(onClick = { onOpen(url) }) { Text(stringResource(R.string.feature_reader_open_original)) }
    }
}

@Composable
private fun Centered(content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) { content() }
}

private fun shareUrl(context: Context, url: String) {
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, url)
    }
    context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}
