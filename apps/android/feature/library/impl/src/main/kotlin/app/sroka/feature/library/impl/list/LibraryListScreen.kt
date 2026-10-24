package app.sroka.feature.library.impl.list

import app.sroka.core.designsystem.icon.SrokaIcons
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.ui.graphics.Color
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.paging.LoadState
import androidx.paging.compose.LazyPagingItems
import androidx.paging.compose.collectAsLazyPagingItems
import androidx.paging.compose.itemContentType
import androidx.paging.compose.itemKey
import app.sroka.core.designsystem.theme.srokaColors
import app.sroka.core.domain.SyncEvent
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SortOrder
import app.sroka.core.model.SyncErrorKind
import app.sroka.core.ui.tags.EditTagsSheet
import app.sroka.core.ui.rememberWithNotificationPermission
import app.sroka.feature.library.impl.R
import kotlinx.coroutines.launch

/**
 * A library list: one of the three tabs or all items with a tag. State lives in
 * [LibraryListViewModel]; rows are paged from local storage so everything works offline.
 *
 * @param onOpenSettings opened by the avatar in the search bar (null on tag lists)
 * @param onOpenSearch opens the full-screen search for the tab (null on tag lists)
 * @param onBack null hides the back arrow (top-level tabs)
 * @param selectedItemId the article open in the detail pane (two-pane only): its row is highlighted
 * @param twoPane the list is the left pane of the list-detail layout: rows are inset as rounded cards
 * @param navRailShown the navigation rail is visible: it hosts the save-link FAB and the avatar, so
 *   the list hides its own
 * @param detailCard the list is drawn inside the detail pane card (tag articles beside the tag list): transparent bars
 * @param addLinkRequested the rail's FAB was tapped: open the add-link dialog, then call [onAddLinkHandled]
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryListRoute(
    scope: ListScope,
    onOpenItem: (String) -> Unit,
    onSignIn: () -> Unit,
    onOpenSettings: (() -> Unit)? = null,
    onOpenSearch: ((LibraryTab) -> Unit)? = null,
    onBack: (() -> Unit)? = null,
    selectedItemId: String? = null,
    twoPane: Boolean = false,
    navRailShown: Boolean = false,
    addLinkRequested: Boolean = false,
    onAddLinkHandled: () -> Unit = {},
    detailCard: Boolean = false,
    viewModel: LibraryListViewModel = hiltViewModel(),
) {
    LaunchedEffect(scope) { viewModel.setScope(scope) }
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val selected by viewModel.selectedItem.collectAsStateWithLifecycle()
    val recentTags by viewModel.recentTags.collectAsStateWithLifecycle()
    val items = viewModel.items.collectAsLazyPagingItems()

    val snackbarHostState = remember { SnackbarHostState() }
    val resources = LocalResources.current
    var pulled by rememberSaveable { mutableStateOf(false) }
    var showAdd by rememberSaveable { mutableStateOf(false) }
    var editTagsFor by remember { mutableStateOf<app.sroka.core.model.Item?>(null) }
    var confirmDeleteFor by remember { mutableStateOf<app.sroka.core.model.Item?>(null) }
    val coroutineScope = rememberCoroutineScope()
    val listState = rememberLazyListState()
    LaunchedEffect(addLinkRequested) {
        if (addLinkRequested && tabScope(scope)) {
            showAdd = true
            onAddLinkHandled()
        }
    }

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
                        SyncErrorKind.STORAGE -> R.string.feature_library_fetch_failed_storage
                    },
                )
            }
            snackbarHostState.currentSnackbarData?.dismiss()
            coroutineScope.launch { snackbarHostState.showSnackbar(message) }
        }
    }
    LaunchedEffect(state.busy) { if (!state.busy) pulled = false }

    val isEmpty = items.loadState.refresh is LoadState.NotLoading && items.itemCount == 0
    val fetch = rememberWithNotificationPermission(viewModel::fetchNewArticles)

    LibraryListContent(
        scope = scope,
        state = state,
        snackbarHostState = snackbarHostState,
        refreshing = pulled && state.busy,
        onRefresh = {
            pulled = true
            fetch()
        },
        isEmpty = isEmpty,
        listState = listState,
        itemCount = { items.itemCount },
        itemAt = { items[it] },
        itemKey = items.itemKey { it.id },
        itemContentType = items.itemContentType { "item" },
        onSortChange = viewModel::setSort,
        onOpenSearch = onOpenSearch,
        onOpenSettings = onOpenSettings,
        onBack = onBack,
        onSignIn = onSignIn,
        onAddLink = { showAdd = true },
        onOpenItem = onOpenItem,
        onLongClick = { viewModel.showActions(it.id) },
        onArchive = { viewModel.toggleArchive(it.id, it.status) },
        selectedItemId = selectedItemId,
        twoPane = twoPane,
        navRailShown = navRailShown,
        detailCard = detailCard,
    )

    selected?.let { item ->
        ItemActionsSheet(
            item = item,
            onDismiss = viewModel::dismissActions,
            onToggleFavorite = { viewModel.toggleFavorite(item.id, item.isFavorite) },
            onToggleArchive = { viewModel.toggleArchive(item.id, item.status) },
            // A second sheet/dialog replaces the actions sheet instead of stacking under it.
            onEditTags = { editTagsFor = item; viewModel.dismissActions() },
            onRefresh = { viewModel.refresh(item.id) },
            onDelete = { confirmDeleteFor = item; viewModel.dismissActions() },
        )
    }
    editTagsFor?.let { item ->
        EditTagsSheet(
            initialTags = item.tags,
            suggestions = recentTags,
            onSave = {
                viewModel.setTags(item.id, it)
                editTagsFor = null
            },
            onDismiss = { editTagsFor = null },
        )
    }
    confirmDeleteFor?.let { item ->
        ConfirmDialog(
            title = stringResource(R.string.feature_library_delete_title),
            body = stringResource(R.string.feature_library_delete_body),
            confirmLabel = stringResource(R.string.feature_library_action_delete),
            onConfirm = {
                viewModel.delete(item.id)
                confirmDeleteFor = null
            },
            onDismiss = { confirmDeleteFor = null },
        )
    }
    if (showAdd) {
        AddUrlDialog(onSubmit = viewModel::addLink, onDismiss = { showAdd = false })
    }
}

/**
 * Stateless list screen: top bar (search pill or title bar), status cards, the list (or empty state),
 * FAB and snackbar host. The route feeds it from the ViewModel; screenshot tests feed it fixtures.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryListContent(
    scope: ListScope,
    state: LibraryListUiState,
    snackbarHostState: SnackbarHostState,
    refreshing: Boolean,
    onRefresh: () -> Unit,
    isEmpty: Boolean,
    listState: LazyListState,
    itemCount: () -> Int,
    itemAt: (Int) -> ItemSummary?,
    itemKey: (Int) -> Any,
    itemContentType: (Int) -> Any?,
    onSortChange: (SortOrder) -> Unit,
    onOpenSearch: ((LibraryTab) -> Unit)?,
    onOpenSettings: (() -> Unit)?,
    onBack: (() -> Unit)?,
    onSignIn: () -> Unit,
    onAddLink: () -> Unit,
    onOpenItem: (String) -> Unit,
    onLongClick: (ItemSummary) -> Unit,
    onArchive: (ItemSummary) -> Unit,
    selectedItemId: String?,
    twoPane: Boolean,
    navRailShown: Boolean,
    detailCard: Boolean = false,
) {
    val tab = (scope as? ListScope.Tab)?.tab
    val isTopLevel = tab != null
    val fabExpanded = isEmpty || listState.isScrollingUpOrAtTop()
    Scaffold(
        containerColor = if (detailCard) Color.Transparent else MaterialTheme.colorScheme.background,
        topBar = {
            if (tab != null) {
                SearchPill(
                    tab = tab,
                    email = state.email,
                    sort = state.sort,
                    onSortChange = onSortChange,
                    onOpenSearch = { onOpenSearch?.invoke(tab) },
                    onOpenSettings = onOpenSettings.takeUnless { navRailShown },
                )
            } else {
                TopAppBar(
                    title = { Text(scopeTitle(scope)) },
                    navigationIcon = {
                        if (onBack != null) {
                            IconButton(onClick = onBack) {
                                Icon(SrokaIcons.ArrowBack, contentDescription = stringResource(R.string.feature_library_back))
                            }
                        }
                    },
                    actions = { SortMenu(state.sort, onSortChange) },
                    colors = if (detailCard) TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent) else TopAppBarDefaults.topAppBarColors(),
                )
            }
        },
        floatingActionButton = {
            if (isTopLevel && !navRailShown) {
                val brand = MaterialTheme.srokaColors
                ExtendedFloatingActionButton(
                    onClick = onAddLink,
                    expanded = fabExpanded,
                    shape = RoundedCornerShape(16.dp),
                    containerColor = brand.brand,
                    contentColor = brand.onBrand,
                    icon = { Icon(SrokaIcons.Add, contentDescription = null) },
                    text = { Text(stringResource(R.string.feature_library_save_link)) },
                )
            }
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            StatusCards(selectStatusCard(state.sync, state.needsSignIn), onSignIn = onSignIn)
            PullToRefreshBox(
                isRefreshing = refreshing,
                onRefresh = onRefresh,
                modifier = Modifier.fillMaxSize(),
            ) {
                if (isEmpty) {
                    EmptyContent(scope)
                } else {
                    ItemList(
                        itemCount = itemCount,
                        itemAt = itemAt,
                        itemKey = itemKey,
                        itemContentType = itemContentType,
                        listState = listState,
                        archiveTab = tab == LibraryTab.ARCHIVE,
                        onOpenItem = onOpenItem,
                        onLongClick = onLongClick,
                        onArchive = onArchive,
                        bottomPadding = if (isTopLevel && !navRailShown) FAB_CLEARANCE else 0.dp,
                        selectedItemId = selectedItemId,
                        inset = twoPane,
                    )
                }
            }
        }
    }
}

/** True at the top of the list or while the last scroll moved up (FAB expanded); false when scrolling down. */
@Composable
private fun LazyListState.isScrollingUpOrAtTop(): Boolean {
    var previousIndex by remember(this) { mutableIntStateOf(firstVisibleItemIndex) }
    var previousOffset by remember(this) { mutableIntStateOf(firstVisibleItemScrollOffset) }
    return remember(this) {
        derivedStateOf {
            val index = firstVisibleItemIndex
            val offset = firstVisibleItemScrollOffset
            val up = when {
                index == 0 && offset == 0 -> true
                index != previousIndex -> index < previousIndex
                else -> offset <= previousOffset
            }
            previousIndex = index
            previousOffset = offset
            up
        }
    }.value
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

/** M3-style search pill (surfaceContainerHigh) with sort and the avatar that opens Settings. */
@Composable
private fun SearchPill(
    tab: LibraryTab,
    email: String,
    sort: SortOrder,
    onSortChange: (SortOrder) -> Unit,
    onOpenSearch: () -> Unit,
    onOpenSettings: (() -> Unit)?,
) {
    val hint = stringResource(
        when (tab) {
            LibraryTab.MY_LIST -> R.string.feature_library_search_bar_my_list
            LibraryTab.FAVORITES -> R.string.feature_library_search_bar_favorites
            LibraryTab.ARCHIVE -> R.string.feature_library_search_bar_archive
        },
    )
    Surface(
        modifier = Modifier
            .windowInsetsPadding(WindowInsets.statusBars)
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .fillMaxWidth()
            .height(56.dp),
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        onClick = onOpenSearch,
    ) {
        Row(
            Modifier.padding(start = 16.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(SrokaIcons.Search, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                hint,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f).padding(start = 16.dp),
            )
            SortMenu(sort, onSortChange)
            if (onOpenSettings != null) Avatar(email, onOpenSettings)
        }
    }
}

@Composable
private fun Avatar(email: String, onClick: () -> Unit) {
    val label = stringResource(R.string.feature_library_settings)
    Box(
        Modifier
            .size(48.dp)
            .clickable(onClick = onClick, role = Role.Button, onClickLabel = label),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(32.dp).background(MaterialTheme.colorScheme.primaryContainer, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                avatarLetter(email),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
        }
    }
}

/** First letter of the account email, upper-cased; "?" when unknown. */
internal fun avatarLetter(email: String): String =
    email.trim().firstOrNull { it.isLetterOrDigit() }?.uppercase() ?: "?"

@Composable
private fun SortMenu(sort: SortOrder, onSortChange: (SortOrder) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(
                SrokaIcons.Sort,
                contentDescription = stringResource(R.string.feature_library_sort),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
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
private fun EmptyContent(scope: ListScope) {
    data class Content(val icon: ImageVector, val title: Int, val body: Int?)
    val content = when {
        scope is ListScope.Tag -> Content(SrokaIcons.Label, R.string.feature_library_empty_tag_title, null)
        scope is ListScope.Tab && scope.tab == LibraryTab.ARCHIVE ->
            Content(SrokaIcons.Archive, R.string.feature_library_empty_archive_title, R.string.feature_library_empty_archive_body)
        scope is ListScope.Tab && scope.tab == LibraryTab.FAVORITES ->
            Content(SrokaIcons.Star, R.string.feature_library_empty_favorites_title, R.string.feature_library_empty_favorites_body)
        else -> Content(SrokaIcons.Inbox, R.string.feature_library_empty_my_list_title, R.string.feature_library_empty_my_list_body)
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

/** 56dp FAB + 16dp margin + 16dp gap; same as the app-level snackbar clearance. */
private val FAB_CLEARANCE = 88.dp

/** Two-pane list: rows are rounded 16dp cards, inset 8dp, with a 2dp gap (R13). */
private val ROW_INSET = 8.dp
private val ROW_GAP = 2.dp
private val rowShape = RoundedCornerShape(16.dp)

private fun tabScope(scope: ListScope) = scope is ListScope.Tab

@Composable
private fun ItemList(
    itemCount: () -> Int,
    itemAt: (Int) -> ItemSummary?,
    itemKey: (Int) -> Any,
    itemContentType: (Int) -> Any?,
    listState: LazyListState,
    archiveTab: Boolean,
    onOpenItem: (String) -> Unit,
    onLongClick: (ItemSummary) -> Unit,
    onArchive: (ItemSummary) -> Unit,
    bottomPadding: Dp,
    selectedItemId: String? = null,
    inset: Boolean = false,
) {
    LazyColumn(
        Modifier.fillMaxSize(),
        state = listState,
        contentPadding = PaddingValues(bottom = bottomPadding),
        verticalArrangement = Arrangement.spacedBy(if (inset) ROW_GAP else 0.dp),
    ) {
        items(
            count = itemCount(),
            key = itemKey,
            contentType = itemContentType,
        ) { index ->
            val item = itemAt(index) ?: return@items
            SwipeableRow(
                modifier = Modifier.animateItem(),
                item = item,
                archiveTab = archiveTab,
                selected = item.id == selectedItemId,
                inset = inset,
                onClick = { onOpenItem(item.id) },
                onLongClick = { onLongClick(item) },
                onArchive = { onArchive(item) },
            )
        }
    }
}

/**
 * End to start archives (or unarchives in the Archive tab). The row always snaps back; if the
 * action moves it out of the list the list animates it away. Favourite toggling is in the long-press sheet.
 */
@Composable
private fun SwipeableRow(
    modifier: Modifier,
    item: ItemSummary,
    archiveTab: Boolean,
    selected: Boolean,
    inset: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onArchive: () -> Unit,
) {
    val currentArchive by rememberUpdatedState(onArchive)
    val coroutineScope = rememberCoroutineScope()
    val state = rememberSwipeToDismissBoxState()
    val unarchive = archiveTab || item.status == ItemStatus.ARCHIVED
    SwipeToDismissBox(
        state = state,
        modifier = if (inset) modifier.padding(horizontal = ROW_INSET).clip(rowShape) else modifier,
        enableDismissFromStartToEnd = false,
        onDismiss = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) currentArchive()
            // The row stays in the list for tag views; reset so it snaps back.
            coroutineScope.launch { state.reset() }
        },
        backgroundContent = {
            // Only while swiping: the primary-coloured action bar would otherwise bleed through the
            // anti-aliased rounded corners of a transparent two-pane row.
            if (state.dismissDirection == SwipeToDismissBoxValue.Settled) return@SwipeToDismissBox
            val label = stringResource(if (unarchive) R.string.feature_library_swipe_unarchive else R.string.feature_library_swipe_archive)
            Row(
                Modifier
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.primary)
                    .padding(horizontal = 20.dp),
                horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp, Alignment.End),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    if (unarchive) SrokaIcons.Unarchive else SrokaIcons.Archive,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimary,
                )
                Text(label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onPrimary)
            }
        },
    ) {
        // A transparent (two-pane) row needs an opaque base while it slides over the action bar.
        val swiping = state.dismissDirection != SwipeToDismissBoxValue.Settled
        Box(if (swiping) Modifier.background(MaterialTheme.colorScheme.background) else Modifier) {
            ItemRow(item = item, onClick = onClick, onLongClick = onLongClick, selected = selected, rounded = inset)
        }
    }
}
