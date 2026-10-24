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
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FormatSize
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.filled.Unarchive
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.MenuDefaults
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
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import app.sroka.core.designsystem.theme.srokaColors
import app.sroka.core.model.ParseStatus
import app.sroka.feature.reader.impl.ReaderEvent
import app.sroka.feature.reader.impl.ReaderHeader
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
import app.sroka.core.ui.tags.EditTagsSheet
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
    val offline by viewModel.offline.collectAsStateWithLifecycle()
    val refreshing by viewModel.refreshing.collectAsStateWithLifecycle()
    val snackbarHost = remember { SnackbarHostState() }
    var scrollTopSignal by remember { mutableStateOf(0) }
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

    val msgRefreshed = stringResource(R.string.feature_reader_refreshed)
    val msgRefreshedPartial = stringResource(R.string.feature_reader_refreshed_partial)
    val msgRefreshFailed = stringResource(R.string.feature_reader_refresh_failed)
    val msgContinued = stringResource(R.string.feature_reader_continued)
    val msgStartOver = stringResource(R.string.feature_reader_start_over)
    val msgPartial = stringResource(R.string.feature_reader_partial_warning)
    val msgMinRead = item?.readingMinutes?.let { stringResource(R.string.feature_reader_min_read_prefix, it) }.orEmpty()
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is ReaderEvent.RefreshSettled -> snackbarHost.showSnackbar(
                    when (event.result) {
                        ParseStatus.OK -> msgRefreshed
                        ParseStatus.PARTIAL -> msgRefreshedPartial
                        else -> msgRefreshFailed
                    },
                )
                is ReaderEvent.ResumedFromProgress -> {
                    val result = snackbarHost.showSnackbar(
                        message = msgContinued,
                        actionLabel = msgStartOver,
                        duration = SnackbarDuration.Long,
                    )
                    if (result == SnackbarResult.ActionPerformed) {
                        viewModel.startOver()
                        scrollTopSignal++
                    }
                }
            }
        }
    }
    LaunchedEffect(state is ReaderUiState.Ready) {
        if (state is ReaderUiState.Ready) viewModel.onArticleShown()
    }
    val settledPartial = remember { booleanArrayOf(false) }
    item?.parseStatus?.takeIf { it != ParseStatus.PENDING }?.let { settledPartial[0] = it == ParseStatus.PARTIAL }

    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        snackbarHost = { SnackbarHost(snackbarHost) },
        topBar = {
            Column {
                TopAppBar(
                    title = {},
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
                                    if (current.isFavorite) Icons.Default.Star else Icons.Default.StarBorder,
                                    stringResource(
                                        if (current.isFavorite) R.string.feature_reader_unfavorite else R.string.feature_reader_favorite,
                                    ),
                                    tint = if (current.isFavorite) MaterialTheme.srokaColors.progress else LocalContentColor.current,
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
                            Box {
                                IconButton(onClick = { menuOpen = true }) {
                                    Icon(Icons.Default.MoreVert, stringResource(R.string.feature_reader_more))
                                }
                                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                                    ReaderMenuItem(R.string.feature_reader_edit_tags, Icons.AutoMirrored.Outlined.Label) {
                                        menuOpen = false; showTags = true
                                    }
                                    ReaderMenuItem(R.string.feature_reader_share, Icons.Outlined.Share) {
                                        menuOpen = false; shareUrl(context, current.url)
                                    }
                                    ReaderMenuItem(R.string.feature_reader_open_browser, Icons.AutoMirrored.Outlined.OpenInNew) {
                                        menuOpen = false; openExternalLink(context, current.url)
                                    }
                                    ReaderMenuItem(R.string.feature_reader_refresh, Icons.Outlined.Refresh, enabled = !offline) {
                                        menuOpen = false; viewModel.refresh()
                                    }
                                    ReaderMenuItem(R.string.feature_reader_text_size, Icons.Outlined.FormatSize) {
                                        menuOpen = false; showAppearance = true
                                    }
                                    HorizontalDivider(Modifier.padding(vertical = 4.dp))
                                    ReaderMenuItem(
                                        R.string.feature_reader_delete,
                                        Icons.Outlined.Delete,
                                        tint = MaterialTheme.colorScheme.error,
                                    ) { menuOpen = false; showDelete = true }
                                }
                            }
                        }
                    },
                    scrollBehavior = scrollBehavior,
                )
                ReadingProgressLine(progress)
            }
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
                    val headerItem = item
                    val headerSite = headerItem?.let { it.siteName?.takeIf(String::isNotBlank) ?: it.domain }
                    val headerTitle = headerItem?.displayTitle
                    val headerPartial = settledPartial[0]
                    val header = if (headerSite != null && headerTitle != null) {
                        ReaderHeader(
                            site = headerSite,
                            title = headerTitle,
                            metaPrefix = msgMinRead,
                            progress = 0f, // only the wrapped document shows progress; see the copy below
                            partialWarning = if (headerPartial) msgPartial else null,
                        )
                    } else {
                        null
                    }
                    // Keyed on the article only: header changes are pushed into the live page by script.
                    val wrapped = remember(s.html, s.baseUrl) {
                        val restore = viewModel.restorePoint()
                        ReaderHtml.wrap(
                            articleHtml = s.html,
                            baseUrl = s.baseUrl,
                            theme = theme,
                            textScale = prefs.readerTextScale,
                            startAnchor = restore.anchor,
                            startProgress = restore.progress,
                            header = header?.copy(progress = restore.progress),
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
                        scrollToTopSignal = scrollTopSignal,
                        headerScript = header?.let(ReaderHtml::headerScript).orEmpty(),
                        modifier = Modifier.fillMaxSize(),
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
            if (refreshing) {
                LinearProgressIndicator(Modifier.fillMaxWidth().align(Alignment.TopStart))
            }
        }
    }

    if (showTags) {
        EditTagsSheet(
            initialTags = item?.tags.orEmpty(),
            suggestions = recentTags,
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
private fun ReadingProgressLine(progress: Float) {
    val colors = MaterialTheme.srokaColors
    Box(
        Modifier
            .fillMaxWidth()
            .height(3.dp)
            .background(colors.progressTrack),
    ) {
        Box(
            Modifier
                .fillMaxHeight()
                .fillMaxWidth(progress.coerceIn(0f, 1f))
                .background(colors.progress),
        )
    }
}

@Composable
private fun ReaderMenuItem(
    textRes: Int,
    icon: ImageVector,
    enabled: Boolean = true,
    tint: Color = Color.Unspecified,
    onClick: () -> Unit,
) {
    val color = if (tint == Color.Unspecified) MaterialTheme.colorScheme.onSurface else tint
    DropdownMenuItem(
        text = { Text(stringResource(textRes), color = color) },
        leadingIcon = {
            Icon(
                icon,
                null,
                tint = if (tint == Color.Unspecified) MaterialTheme.colorScheme.onSurfaceVariant else tint,
            )
        },
        enabled = enabled,
        onClick = onClick,
    )
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
