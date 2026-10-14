package app.sroka.feature.library.impl.list

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material.icons.outlined.SearchOff
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.paging.LoadState
import androidx.paging.compose.LazyPagingItems
import androidx.paging.compose.collectAsLazyPagingItems
import androidx.paging.compose.itemContentType
import androidx.paging.compose.itemKey
import app.sroka.core.domain.SyncEvent
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SortOrder
import app.sroka.core.model.SyncErrorKind
import app.sroka.feature.library.impl.R
import kotlinx.coroutines.launch

/**
 * A library list: one of the three tabs or all items with a tag. State lives in
 * [LibraryListViewModel]; rows are paged from local storage so everything works offline.
 *
 * @param onOpenSettings null hides the settings action (tag lists)
 * @param onBack null hides the back arrow (top-level tabs)
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryListRoute(
    scope: ListScope,
    onOpenItem: (String) -> Unit,
    onSignIn: () -> Unit,
    onOpenSettings: (() -> Unit)? = null,
    onBack: (() -> Unit)? = null,
    viewModel: LibraryListViewModel = hiltViewModel(),
) {
    LaunchedEffect(scope) { viewModel.setScope(scope) }
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val selected by viewModel.selectedItem.collectAsStateWithLifecycle()
    val recentTags by viewModel.recentTags.collectAsStateWithLifecycle()
    val items = viewModel.items.collectAsLazyPagingItems()

    val snackbarHostState = remember { SnackbarHostState() }
    val resources = LocalResources.current
    var searching by rememberSaveable { mutableStateOf(false) }
    var pulled by rememberSaveable { mutableStateOf(false) }
    var showAdd by rememberSaveable { mutableStateOf(false) }
    var editTagsFor by remember { mutableStateOf<String?>(null) }
    var confirmDeleteFor by remember { mutableStateOf<String?>(null) }
    val coroutineScope = rememberCoroutineScope()

    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            // collectLatest-like behavior: a newer message replaces the current one.
            snackbarHostState.currentSnackbarData?.dismiss()
            coroutineScope.launch {
                when (event) {
                    is ListEvent.Info -> snackbarHostState.showSnackbar(resources.getString(event.message))
                    is ListEvent.Undoable -> {
                        val result = snackbarHostState.showSnackbar(
                            message = resources.getString(event.message),
                            actionLabel = resources.getString(R.string.feature_library_undo),
                            duration = SnackbarDuration.Short,
                        )
                        if (result == SnackbarResult.ActionPerformed) viewModel.undo(event.undo)
                    }
                }
            }
        }
    }
    LaunchedEffect(viewModel) {
        viewModel.fetchEvents.collect { event ->
            pulled = false
            val message = when (event) {
                is SyncEvent.FetchCompleted ->
                    if (event.newlyDownloaded == 0) {
                        resources.getString(R.string.feature_library_fetch_up_to_date)
                    } else {
                        resources.getQuantityString(R.plurals.feature_library_fetch_done, event.newlyDownloaded, event.newlyDownloaded)
                    }
                is SyncEvent.FetchFailed -> resources.getString(
                    when (event.kind) {
                        SyncErrorKind.NETWORK -> R.string.feature_library_fetch_failed_network
                        SyncErrorKind.SERVER -> R.string.feature_library_fetch_failed_server
                        SyncErrorKind.AUTH -> R.string.feature_library_fetch_failed_auth
                    },
                )
            }
            snackbarHostState.currentSnackbarData?.dismiss()
            coroutineScope.launch { snackbarHostState.showSnackbar(message) }
        }
    }
    LaunchedEffect(state.busy) { if (!state.busy) pulled = false }
    BackHandler(enabled = searching) {
        searching = false
        viewModel.onSearchTextChange("")
    }

    val isEmpty = items.loadState.refresh is LoadState.NotLoading && items.itemCount == 0
    val isTopLevel = scope is ListScope.Tab

    Scaffold(
        topBar = {
            ListTopBar(
                title = scopeTitle(scope),
                searching = searching,
                searchText = state.searchText,
                sort = state.sort,
                onSearchTextChange = viewModel::onSearchTextChange,
                onStartSearch = { searching = true },
                onCloseSearch = {
                    searching = false
                    viewModel.onSearchTextChange("")
                },
                onSortChange = viewModel::setSort,
                onFetch = viewModel::fetchNewArticles,
                onOpenSettings = onOpenSettings,
                onBack = onBack,
            )
        },
        floatingActionButton = {
            if (isTopLevel && !searching) {
                ExtendedFloatingActionButton(
                    onClick = { showAdd = true },
                    expanded = isEmpty,
                    icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                    text = { Text(stringResource(R.string.feature_library_add)) },
                )
            }
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            SyncStrip(phase = state.sync.phase, needsSignIn = state.needsSignIn, onSignIn = onSignIn)
            PullToRefreshBox(
                isRefreshing = pulled && state.busy,
                onRefresh = {
                    pulled = true
                    viewModel.fetchNewArticles()
                },
                modifier = Modifier.fillMaxSize(),
            ) {
                if (isEmpty) {
                    EmptyContent(scope, searching = state.searchText.isNotBlank())
                } else {
                    ItemList(
                        items = items,
                        archiveTab = (scope as? ListScope.Tab)?.tab == LibraryTab.ARCHIVE,
                        onOpenItem = onOpenItem,
                        onLongClick = { viewModel.showActions(it.id) },
                        onArchive = { viewModel.toggleArchive(it.id, it.status) },
                        onFavorite = { viewModel.toggleFavorite(it.id, it.isFavorite) },
                    )
                }
            }
        }
    }

    selected?.let { item ->
        ItemActionsSheet(
            item = item,
            onDismiss = viewModel::dismissActions,
            onToggleFavorite = { viewModel.toggleFavorite(item.id, item.isFavorite) },
            onToggleArchive = { viewModel.toggleArchive(item.id, item.status) },
            onEditTags = { editTagsFor = item.id },
            onRefresh = { viewModel.refresh(item.id) },
            onDelete = { confirmDeleteFor = item.id },
        )
        if (editTagsFor == item.id) {
            EditTagsDialog(
                initialTags = item.tags,
                suggestions = recentTags,
                onSave = {
                    viewModel.setTags(item.id, it)
                    editTagsFor = null
                    viewModel.dismissActions()
                },
                onDismiss = { editTagsFor = null },
            )
        }
        if (confirmDeleteFor == item.id) {
            ConfirmDialog(
                title = stringResource(R.string.feature_library_delete_title),
                body = stringResource(R.string.feature_library_delete_body),
                confirmLabel = stringResource(R.string.feature_library_action_delete),
                onConfirm = {
                    viewModel.delete(item.id)
                    confirmDeleteFor = null
                    viewModel.dismissActions()
                },
                onDismiss = { confirmDeleteFor = null },
            )
        }
    }
    if (showAdd) {
        AddUrlDialog(onSubmit = viewModel::addLink, onDismiss = { showAdd = false })
    }
}

@Composable
private fun scopeTitle(scope: ListScope): String = when (scope) {
    is ListScope.Tag -> scope.name
    is ListScope.Tab -> stringResource(
        when (scope.tab) {
            LibraryTab.MY_LIST -> R.string.feature_library_my_list
            LibraryTab.ARCHIVE -> R.string.feature_library_archive
            LibraryTab.FAVORITES -> R.string.feature_library_favorites
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ListTopBar(
    title: String,
    searching: Boolean,
    searchText: String,
    sort: SortOrder,
    onSearchTextChange: (String) -> Unit,
    onStartSearch: () -> Unit,
    onCloseSearch: () -> Unit,
    onSortChange: (SortOrder) -> Unit,
    onFetch: () -> Unit,
    onOpenSettings: (() -> Unit)?,
    onBack: (() -> Unit)?,
) {
    if (searching) {
        val focus = remember { FocusRequester() }
        LaunchedEffect(Unit) { focus.requestFocus() }
        TopAppBar(
            navigationIcon = {
                IconButton(onClick = onCloseSearch) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.feature_library_close_search))
                }
            },
            title = {
                TextField(
                    value = searchText,
                    onValueChange = onSearchTextChange,
                    placeholder = { Text(stringResource(R.string.feature_library_search_hint)) },
                    singleLine = true,
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = androidx.compose.ui.graphics.Color.Transparent,
                        unfocusedContainerColor = androidx.compose.ui.graphics.Color.Transparent,
                        focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                        unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                    ),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = {}),
                    modifier = Modifier.focusRequester(focus),
                )
            },
            actions = {
                if (searchText.isNotEmpty()) {
                    IconButton(onClick = { onSearchTextChange("") }) {
                        Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.feature_library_clear_search))
                    }
                }
            },
        )
        return
    }
    TopAppBar(
        title = { Text(title) },
        navigationIcon = {
            if (onBack != null) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.feature_library_back))
                }
            }
        },
        actions = {
            IconButton(onClick = onStartSearch) {
                Icon(Icons.Filled.Search, contentDescription = stringResource(R.string.feature_library_search))
            }
            IconButton(onClick = onFetch) {
                Icon(Icons.Filled.CloudDownload, contentDescription = stringResource(R.string.feature_library_fetch))
            }
            SortMenu(sort, onSortChange)
            if (onOpenSettings != null) {
                IconButton(onClick = onOpenSettings) {
                    Icon(Icons.Filled.Settings, contentDescription = stringResource(R.string.feature_library_settings))
                }
            }
        },
    )
}

@Composable
private fun SortMenu(sort: SortOrder, onSortChange: (SortOrder) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(Icons.AutoMirrored.Filled.Sort, contentDescription = stringResource(R.string.feature_library_sort))
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            SortOrder.entries.forEach { order ->
                DropdownMenuItem(
                    text = { Text(stringResource(order.label())) },
                    leadingIcon = { RadioButton(selected = order == sort, onClick = null) },
                    onClick = {
                        onSortChange(order)
                        expanded = false
                    },
                )
            }
        }
    }
}

private fun SortOrder.label(): Int = when (this) {
    SortOrder.NEWEST -> R.string.feature_library_sort_newest
    SortOrder.OLDEST -> R.string.feature_library_sort_oldest
    SortOrder.SHORTEST -> R.string.feature_library_sort_shortest
    SortOrder.LONGEST -> R.string.feature_library_sort_longest
}

@Composable
private fun EmptyContent(scope: ListScope, searching: Boolean) {
    data class Content(val icon: ImageVector, val title: Int, val body: Int?)
    val content = when {
        searching -> Content(Icons.Outlined.SearchOff, R.string.feature_library_empty_search_title, R.string.feature_library_empty_search_body)
        scope is ListScope.Tag -> Content(Icons.AutoMirrored.Outlined.Label, R.string.feature_library_empty_tag_title, null)
        scope is ListScope.Tab && scope.tab == LibraryTab.ARCHIVE ->
            Content(Icons.Outlined.Archive, R.string.feature_library_empty_archive_title, R.string.feature_library_empty_archive_body)
        scope is ListScope.Tab && scope.tab == LibraryTab.FAVORITES ->
            Content(Icons.Outlined.StarBorder, R.string.feature_library_empty_favorites_title, R.string.feature_library_empty_favorites_body)
        else -> Content(Icons.Outlined.Inbox, R.string.feature_library_empty_my_list_title, R.string.feature_library_empty_my_list_body)
    }
    // Scrollable so pull-to-refresh also works on an empty list.
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            app.sroka.core.designsystem.component.SrokaEmptyState(
                icon = content.icon,
                title = stringResource(content.title),
                description = content.body?.let { stringResource(it) },
                modifier = Modifier.fillParentMaxSize(),
            )
        }
    }
}

@Composable
private fun ItemList(
    items: LazyPagingItems<ItemSummary>,
    archiveTab: Boolean,
    onOpenItem: (String) -> Unit,
    onLongClick: (ItemSummary) -> Unit,
    onArchive: (ItemSummary) -> Unit,
    onFavorite: (ItemSummary) -> Unit,
) {
    LazyColumn(Modifier.fillMaxSize()) {
        items(
            count = items.itemCount,
            key = items.itemKey { it.id },
            contentType = items.itemContentType { "item" },
        ) { index ->
            val item = items[index] ?: return@items
            SwipeableRow(
                modifier = Modifier.animateItem(),
                item = item,
                archiveTab = archiveTab,
                onClick = { onOpenItem(item.id) },
                onLongClick = { onLongClick(item) },
                onArchive = { onArchive(item) },
                onFavorite = { onFavorite(item) },
            )
        }
    }
}

/**
 * End to start archives (or restores), start to end toggles favorite. The row always snaps back;
 * if the action moves it out of the list the list animates it away.
 */
@Composable
private fun SwipeableRow(
    modifier: Modifier,
    item: ItemSummary,
    archiveTab: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onArchive: () -> Unit,
    onFavorite: () -> Unit,
) {
    val currentArchive by rememberUpdatedState(onArchive)
    val currentFavorite by rememberUpdatedState(onFavorite)
    val coroutineScope = rememberCoroutineScope()
    val state = rememberSwipeToDismissBoxState()
    SwipeToDismissBox(
        state = state,
        modifier = modifier,
        onDismiss = { value ->
            when (value) {
                SwipeToDismissBoxValue.EndToStart -> currentArchive()
                SwipeToDismissBoxValue.StartToEnd -> currentFavorite()
                SwipeToDismissBoxValue.Settled -> Unit
            }
            // The row stays in the list for tag views; reset so it snaps back.
            coroutineScope.launch { state.reset() }
        },
        backgroundContent = {
            val toStart = state.dismissDirection == SwipeToDismissBoxValue.EndToStart
            val (icon, label, color, alignment) = if (toStart) {
                SwipeVisual(
                    Icons.Filled.Archive,
                    stringResource(if (archiveTab || item.status == ItemStatus.ARCHIVED) R.string.feature_library_swipe_unarchive else R.string.feature_library_swipe_archive),
                    MaterialTheme.colorScheme.secondaryContainer,
                    Alignment.CenterEnd,
                )
            } else {
                SwipeVisual(
                    Icons.Filled.Star,
                    stringResource(if (item.isFavorite) R.string.feature_library_swipe_unfavorite else R.string.feature_library_swipe_favorite),
                    MaterialTheme.colorScheme.tertiaryContainer,
                    Alignment.CenterStart,
                )
            }
            Box(
                Modifier.fillMaxSize().background(color).padding(horizontal = 24.dp),
                contentAlignment = alignment,
            ) {
                Icon(icon, contentDescription = label)
            }
        },
    ) {
        ItemRow(item = item, onClick = onClick, onLongClick = onLongClick)
    }
}

private data class SwipeVisual(
    val icon: ImageVector,
    val label: String,
    val color: androidx.compose.ui.graphics.Color,
    val alignment: Alignment,
)
