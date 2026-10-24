package app.sroka

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.sroka.core.designsystem.component.DetailPaneCard
import app.sroka.core.designsystem.theme.SrokaTheme
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.PendingChange
import app.sroka.core.model.MatchIn
import app.sroka.core.model.SearchResult
import app.sroka.core.model.SearchScope
import app.sroka.core.model.TagCount
import app.sroka.feature.library.impl.search.SearchContent
import app.sroka.feature.library.impl.tags.TagsContent
import app.sroka.feature.library.impl.list.LibraryListContent
import app.sroka.feature.library.impl.list.LibraryListUiState
import app.sroka.feature.library.impl.list.ListScope
import app.sroka.feature.library.impl.detail.DetailPlaceholderContent
import app.sroka.navigation.PaneDividerHandle
import app.sroka.navigation.RailDestination
import app.sroka.navigation.SrokaRail
import app.sroka.navigation.TopLevelDestination
import com.android.tools.screenshot.PreviewTest

// The unfolded two-pane shell (R13, screen 17), assembled from the same stateless parts the real
// shell uses. NavDisplay and the reader's WebView cannot render in layoutlib, so the detail pane is
// the empty-state placeholder or a stub article inside the real DetailPaneCard.

@Preview(name = "Unfolded", showBackground = true, widthDp = 673, heightDp = 841, apiLevel = 36)
@Preview(name = "Unfolded landscape", showBackground = true, widthDp = 841, heightDp = 673, apiLevel = 36)
private annotation class UnfoldedPreviews

private fun row(
    id: String,
    title: String,
    domain: String,
    minutes: Int?,
    favorite: Boolean = false,
    offline: OfflineState = OfflineState.AVAILABLE_REMOTE,
    pending: PendingChange? = null,
    parse: ParseStatus = ParseStatus.OK,
) = ItemSummary(
    id = id, displayTitle = title, domain = domain, excerpt = null, readingMinutes = minutes,
    status = ItemStatus.UNREAD, isFavorite = favorite, progress = 0f, parseStatus = parse,
    offline = offline, thumbnailPath = null, tags = emptyList(), savedAt = 1_768_473_000_000L,
    pendingChange = pending,
)

private val shellItems = listOf(
    row("i1", "How a magpie decides what to collect", "nature.example.org", 9, favorite = true, offline = OfflineState.DOWNLOADED),
    row("i2", "The slow web: why reading later still matters", "longreads.example.com", 14),
    row("i3", "A saved link that has not reached the server yet", "draft.example.net", null, pending = PendingChange.SAVE),
    row("i4", "A page that only half parsed", "partial.example.com", 6, parse = ParseStatus.PARTIAL),
    row("i5", "Available offline on this device", "saved.example.com", 8, offline = OfflineState.DOWNLOADED),
)

@Composable
private fun ShellFixture(
    darkTheme: Boolean,
    selectedTab: Int = 0,
    listCollapsed: Boolean = false,
    list: @Composable () -> Unit = { MyListPane() },
    detail: @Composable () -> Unit,
) {
    SrokaTheme(darkTheme = darkTheme) {
        Row(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
            SrokaRail(
                destinations = TopLevelDestination.entries.map {
                    RailDestination(stringResourceFor(it.label), it.unselectedIcon, it.selectedIcon)
                },
                selectedIndex = selectedTab,
                avatarLetter = "M",
                onSaveLink = {},
                onSelect = {},
                onOpenSettings = {},
            )
            if (!listCollapsed) {
                Box(Modifier.width(360.dp).fillMaxHeight()) { list() }
                Box(Modifier.width(24.dp).fillMaxHeight(), contentAlignment = Alignment.Center) { PaneDividerHandle() }
            }
            Box(Modifier.weight(1f).fillMaxHeight()) { detail() }
        }
    }
}

@Composable
private fun MyListPane() {
                LibraryListContent(
                    scope = ListScope.Tab(LibraryTab.MY_LIST),
                    state = LibraryListUiState(email = "magpie@example.com"),
                    snackbarHostState = remember { SnackbarHostState() },
                    refreshing = false,
                    onRefresh = {},
                    isEmpty = false,
                    listState = rememberLazyListState(),
                    itemCount = { shellItems.size },
                    itemAt = { shellItems.getOrNull(it) },
                    itemKey = { shellItems[it].id },
                    itemContentType = { "item" },
                    onSortChange = {},
                    onOpenSearch = {},
                    onOpenSettings = null,
                    onBack = null,
                    onSignIn = {},
                    onAddLink = {},
                    onOpenItem = {},
                    onLongClick = {},
                    onArchive = {},
                    selectedItemId = "i2",
                    twoPane = true,
                    navRailShown = true,
                )
            }

@Composable
private fun stringResourceFor(id: Int): String = androidx.compose.ui.res.stringResource(id)

@Composable
private fun StubArticle(centered: Boolean = false) {
    DetailPaneCard {
        Column(
            Modifier.then(if (centered) Modifier.align(Alignment.TopCenter) else Modifier)
                .widthIn(max = 640.dp).padding(horizontal = 48.dp, vertical = 32.dp),
        ) {
            Text("longreads.example.com", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            Text(
                "The slow web: why reading later still matters",
                fontSize = 36.sp,
                lineHeight = 42.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(vertical = 12.dp),
            )
            Text("14 min read · 0%", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                "Reading later only works when the library stays small enough to trust. " +
                    "This stub stands in for the reader, whose WebView does not render in screenshot tests.",
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.padding(top = 24.dp),
            )
        }
    }
}

@PreviewTest
@UnfoldedPreviews
@Composable
fun ShellPlaceholderLight() = ShellFixture(darkTheme = false) { DetailPlaceholderContent(nextTitle = "How a magpie decides what to collect", onReadNext = {}) }

@PreviewTest
@UnfoldedPreviews
@Composable
fun ShellReaderLight() = ShellFixture(darkTheme = false) { StubArticle() }

@PreviewTest
@UnfoldedPreviews
@Composable
fun ShellPlaceholderDark() = ShellFixture(darkTheme = true) { DetailPlaceholderContent(nextTitle = "How a magpie decides what to collect", onReadNext = {}) }

@PreviewTest
@UnfoldedPreviews
@Composable
fun ShellReaderDark() = ShellFixture(darkTheme = true) { StubArticle() }

@Composable
private fun SearchPane() {
    SearchContent(
        query = "slow web",
        scope = SearchScope.ALL,
        loaded = true,
        itemCount = 2,
        itemAt = {
            SearchResult(
                shellItems[it],
                MatchIn.TEXT,
                "Reading later only works when the library stays small enough to trust, like the slow web.",
                listOf(66..73),
            )
        },
        itemKey = { shellItems[it].id },
        resultCount = 2,
        onQueryChange = {},
        onScopeChange = {},
        onOpenItem = {},
        onBack = {},
        focus = null,
        selectedItemId = "i2",
        twoPane = true,
    )
}

@Composable
private fun TagsPane() {
    TagsContent(
        tags = listOf(TagCount("design", 4), TagCount("longreads", 12), TagCount("nature", 7), TagCount("tech", 21)),
        avatar = "M",
        selectedTag = "nature",
        navRailShown = true,
        onOpenTag = {},
        onOpenSettings = {},
        onRename = {},
        onDelete = {},
    )
}

@Composable
private fun TagItemsPane() {
    DetailPaneCard {
        LibraryListContent(
            scope = ListScope.Tag("nature"),
            state = LibraryListUiState(email = "magpie@example.com"),
            snackbarHostState = remember { SnackbarHostState() },
            refreshing = false,
            onRefresh = {},
            isEmpty = false,
            listState = rememberLazyListState(),
            itemCount = { 2 },
            itemAt = { shellItems.getOrNull(it) },
            itemKey = { shellItems[it].id },
            itemContentType = { "item" },
            onSortChange = {},
            onOpenSearch = null,
            onOpenSettings = null,
            onBack = null,
            onSignIn = {},
            onAddLink = {},
            onOpenItem = {},
            onLongClick = {},
            onArchive = {},
            selectedItemId = null,
            twoPane = true,
            navRailShown = true,
            detailCard = true,
        )
    }
}

@PreviewTest
@UnfoldedPreviews
@Composable
fun ShellSearchLight() = ShellFixture(darkTheme = false, list = { SearchPane() }) { StubArticle() }

@PreviewTest
@UnfoldedPreviews
@Composable
fun ShellSearchEmptyDetailDark() = ShellFixture(darkTheme = true, list = { SearchPane() }) {
    DetailPlaceholderContent(nextTitle = null, onReadNext = {})
}

@PreviewTest
@UnfoldedPreviews
@Composable
fun ShellTagsDark() = ShellFixture(darkTheme = true, selectedTab = 3, list = { TagsPane() }) { TagItemsPane() }

@PreviewTest
@UnfoldedPreviews
@Composable
fun ShellTagsLight() = ShellFixture(darkTheme = false, selectedTab = 3, list = { TagsPane() }) { TagItemsPane() }

/** R14.3: list pane collapsed to 0, rail stays, the reader card spans the rest (column stays <= 640dp, centred). */
@PreviewTest
@UnfoldedPreviews
@Composable
fun ShellReaderExpandedLight() = ShellFixture(darkTheme = false, listCollapsed = true) { StubArticle(centered = true) }
