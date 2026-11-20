package app.sroka

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.component.DetailPaneCard
import app.sroka.core.designsystem.theme.SrokaTheme
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.MatchIn
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.SearchResult
import app.sroka.core.model.SearchScope
import app.sroka.core.model.TagCount
import app.sroka.feature.library.impl.detail.DetailPlaceholderContent
import app.sroka.feature.library.impl.list.LibraryListContent
import app.sroka.feature.library.impl.list.LibraryListUiState
import app.sroka.feature.library.impl.list.ListScope
import app.sroka.feature.library.impl.search.SearchContent
import app.sroka.feature.library.impl.tags.TagsContent
import app.sroka.navigation.PaneDividerHandle
import app.sroka.navigation.RailDestination
import app.sroka.navigation.SrokaRail
import app.sroka.navigation.TopLevelDestination
import com.android.tools.screenshot.PreviewTest

// Google Play foldable screenshots, unfolded inner screen: the same rail + 360dp list pane + detail pane shell as
// ShellScreenshotTests, with the made-up store articles. The detail pane is the empty "Read next" state or a
// tag's items (the reader's WebView does not render here). Sizes at 320dpi, so px = 2 x dp:
//   1:1  760x760dp  -> 1520x1520 px        4:3  880x660dp -> 1760x1320 px

private const val StoreSavedAt = 1_768_473_000_000L

private fun row(id: String, title: String, domain: String, minutes: Int, favorite: Boolean = false, progress: Float = 0f) = ItemSummary(
    id = id, displayTitle = title, domain = domain, excerpt = null, readingMinutes = minutes,
    status = ItemStatus.UNREAD, isFavorite = favorite, progress = progress, parseStatus = ParseStatus.OK,
    offline = OfflineState.DOWNLOADED, thumbnailPath = null, tags = emptyList(), savedAt = StoreSavedAt,
)

private val storeItems = listOf(
    row("s1", "How a magpie decides what to collect", "nature.example.org", 9, favorite = true, progress = 0.4f),
    row("s2", "The slow web: why reading later still matters", "longreads.example.com", 14),
    row("s3", "A field guide to quiet mornings", "slowliving.example.net", 6),
    row("s4", "Notes on tagging a growing library", "blog.example.dev", 5, favorite = true),
    row("s5", "Why small tools outlast big platforms", "craft.example.io", 11),
    row("s6", "The case for a paper notebook", "analog.example.com", 4),
    row("s7", "Sourdough, explained without the myths", "kitchen.example.org", 8),
    row("s8", "What a decade of commuting taught me", "essays.example.net", 12),
)

private val storeContinue = listOf(
    row("c1", "How a magpie decides what to collect", "nature.example.org", 9, progress = 0.4f),
    row("c2", "The slow web: why reading later still matters", "longreads.example.com", 14, progress = 0.72f),
)

private val storeTags = listOf(
    TagCount("birds", 6), TagCount("cooking", 9), TagCount("design", 14),
    TagCount("longreads", 23), TagCount("nature", 4), TagCount("tech", 31),
)

private val storeSearch = listOf(
    SearchResult(
        storeItems[0], MatchIn.BOTH,
        "Magpies are known to collect shiny objects, but the story is more about curiosity than greed.", listOf(0..6),
    ),
    SearchResult(
        storeItems[1], MatchIn.TEXT,
        "Reading later only works when the library stays small enough to trust, like a magpie nest.", listOf(78..83),
    ),
    SearchResult(
        storeItems[2], MatchIn.TEXT, "Crows, ravens and magpies share a surprising talent for planning ahead.", listOf(18..24),
    ),
)

@Composable
private fun StoreShell(
    dark: Boolean,
    selectedTab: Int = 0,
    list: @Composable () -> Unit,
    detail: @Composable () -> Unit,
) {
    SrokaTheme(darkTheme = dark) {
        Row(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
            SrokaRail(
                destinations = TopLevelDestination.entries.map {
                    RailDestination(stringResource(it.label), it.unselectedIcon, it.selectedIcon)
                },
                selectedIndex = selectedTab,
                avatarLetter = "M",
                onSaveLink = {},
                onSelect = {},
                onOpenSettings = {},
            )
            Box(Modifier.width(360.dp).fillMaxHeight()) { list() }
            Box(Modifier.width(24.dp).fillMaxHeight(), contentAlignment = Alignment.Center) { PaneDividerHandle() }
            Box(Modifier.weight(1f).fillMaxHeight()) { detail() }
        }
    }
}

@Composable
private fun StoreListPane(selectedItemId: String?) {
    LibraryListContent(
        scope = ListScope.Tab(LibraryTab.MY_LIST),
        state = LibraryListUiState(email = "magpie@example.com"),
        snackbarHostState = remember { SnackbarHostState() },
        refreshing = false,
        onRefresh = {},
        isEmpty = false,
        listState = rememberLazyListState(),
        itemCount = { storeItems.size },
        itemAt = { storeItems.getOrNull(it) },
        itemKey = { storeItems[it].id },
        itemContentType = { "item" },
        onSortChange = {},
        onOpenSearch = {},
        onOpenSettings = null,
        onBack = null,
        onSignIn = {},
        onAddLink = {},
        onOpenItem = {},
        onLongClick = {},
        selectedItemId = selectedItemId,
        twoPane = true,
        navRailShown = true,
        topTags = listOf("birds", "longreads", "design", "cooking"),
        onOpenTags = {},
        continueReading = storeContinue,
    )
}

@Composable
private fun ReadNextPane() =
    DetailPlaceholderContent(nextTitle = "How a magpie decides what to collect", onReadNext = {})

@Composable
private fun StoreTagsPane() {
    TagsContent(
        tags = storeTags, avatar = "M", selectedTag = "nature", navRailShown = true,
        onOpenTag = {}, onOpenSettings = {}, onRename = {}, onDelete = {},
    )
}

@Composable
private fun StoreTagItemsPane() {
    DetailPaneCard {
        LibraryListContent(
            scope = ListScope.Tag("nature"),
            state = LibraryListUiState(email = "magpie@example.com"),
            snackbarHostState = remember { SnackbarHostState() },
            refreshing = false,
            onRefresh = {},
            isEmpty = false,
            listState = rememberLazyListState(),
            itemCount = { 4 },
            itemAt = { storeItems.getOrNull(it) },
            itemKey = { storeItems[it].id },
            itemContentType = { "item" },
            onSortChange = {},
            onOpenSearch = null,
            onOpenSettings = null,
            onBack = null,
            onSignIn = {},
            onAddLink = {},
            onOpenItem = {},
            onLongClick = {},
            selectedItemId = null,
            twoPane = true,
            navRailShown = true,
            detailCard = true,
        )
    }
}

@Composable
private fun StoreSearchPane() {
    SearchContent(
        query = "magpie", scope = SearchScope.ALL, loaded = true,
        itemCount = storeSearch.size, itemAt = { storeSearch.getOrNull(it) }, itemKey = { storeSearch[it].summary.id },
        resultCount = storeSearch.size, onQueryChange = {}, onScopeChange = {}, onOpenItem = {}, onBack = {}, focus = null,
        selectedItemId = null, twoPane = true,
    )
}

/** 1:1: library list beside the empty detail pane with "Read next". */
@PreviewTest
@Preview(name = "StoreFoldUnfoldedLibrary", showBackground = true, device = "spec:width=760dp,height=760dp,dpi=320", apiLevel = 36)
@Composable
fun StoreFoldUnfoldedLibrary() = StoreShell(dark = false, list = { StoreListPane(null) }) { ReadNextPane() }

/** 1:1 dark. */
@PreviewTest
@Preview(name = "StoreFoldUnfoldedLibraryDark", showBackground = true, device = "spec:width=760dp,height=760dp,dpi=320", apiLevel = 36)
@Composable
fun StoreFoldUnfoldedLibraryDark() = StoreShell(dark = true, list = { StoreListPane(null) }) { ReadNextPane() }

/** 4:3: tags list pane with the open tag's articles beside it. */
@PreviewTest
@Preview(name = "StoreFoldUnfoldedTags", showBackground = true, device = "spec:width=880dp,height=660dp,dpi=320", apiLevel = 36)
@Composable
fun StoreFoldUnfoldedTags() = StoreShell(dark = false, selectedTab = 2, list = { StoreTagsPane() }) { StoreTagItemsPane() }

/** 4:3: full-text search results pane beside the empty detail pane. */
@PreviewTest
@Preview(name = "StoreFoldUnfoldedSearch", showBackground = true, device = "spec:width=880dp,height=660dp,dpi=320", apiLevel = 36)
@Composable
fun StoreFoldUnfoldedSearch() = StoreShell(dark = false, list = { StoreSearchPane() }) { ReadNextPane() }
