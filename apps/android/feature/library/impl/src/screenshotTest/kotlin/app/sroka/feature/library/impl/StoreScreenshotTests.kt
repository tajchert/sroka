package app.sroka.feature.library.impl

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.theme.SrokaTheme
import app.sroka.core.model.Item
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.MatchIn
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.SearchResult
import app.sroka.core.model.SearchScope
import app.sroka.core.model.TagCount
import app.sroka.feature.library.impl.list.LibraryListContent
import app.sroka.feature.library.impl.list.LibraryListUiState
import app.sroka.feature.library.impl.list.ListScope
import app.sroka.feature.library.impl.save.JustSaved
import app.sroka.feature.library.impl.search.SearchContent
import app.sroka.feature.library.impl.tags.TagsContent
import com.android.tools.screenshot.PreviewTest

// Google Play phone screenshots: 360x640dp at 480dpi renders 1080x1920 px. Made-up articles only.

private const val StoreSavedAt = 1_768_473_000_000L

private fun row(
    id: String,
    title: String,
    domain: String,
    minutes: Int,
    favorite: Boolean = false,
    progress: Float = 0f,
    offline: OfflineState = OfflineState.DOWNLOADED,
    status: ItemStatus = ItemStatus.UNREAD,
) = ItemSummary(
    id = id, displayTitle = title, domain = domain, excerpt = null, readingMinutes = minutes,
    status = status, isFavorite = favorite, progress = progress, parseStatus = ParseStatus.OK,
    offline = offline, thumbnailPath = null, tags = emptyList(), savedAt = StoreSavedAt,
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
    row("c3", "A field guide to corvid intelligence", "birds.example.org", 7, progress = 0.1f),
)

private val storeTags = listOf(
    TagCount("birds", 6), TagCount("cooking", 9), TagCount("design", 14),
    TagCount("longreads", 23), TagCount("nature", 11), TagCount("tech", 31),
)

@Composable
private fun StoreList(dark: Boolean) {
    SrokaTheme(darkTheme = dark) {
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
            onOpenSettings = {},
            onBack = null,
            onSignIn = {},
            onAddLink = {},
            onOpenItem = {},
            onLongClick = {},
            selectedItemId = null,
            twoPane = false,
            navRailShown = false,
            topTags = listOf("birds", "longreads", "design", "cooking"),
            onOpenTags = {},
            continueReading = storeContinue,
        )
    }
}

@PreviewTest
@Preview(name = "StorePhoneLibraryLight", showBackground = true, device = "spec:width=360dp,height=640dp,dpi=480", apiLevel = 36)
@Composable
fun StorePhoneLibraryLight() = StoreList(dark = false)

@PreviewTest
@Preview(name = "StorePhoneLibraryDark", showBackground = true, device = "spec:width=360dp,height=640dp,dpi=480", apiLevel = 36)
@Composable
fun StorePhoneLibraryDark() = StoreList(dark = true)

@PreviewTest
@Preview(name = "StorePhoneSaved", showBackground = true, device = "spec:width=360dp,height=640dp,dpi=480", apiLevel = 36)
@Composable
fun StorePhoneSaved() {
    val saved = Item(
        id = "s9", url = "https://nature.example.org/magpie-collecting", canonicalUrl = "https://nature.example.org/magpie-collecting",
        title = "The quiet intelligence of crows and magpies", excerpt = null, siteName = "Nature Example", author = null, lang = "en",
        leadImageKey = null, wordCount = 1800, readingMinutes = 8, contentId = "c9", contentPrivate = false,
        parseStatus = ParseStatus.OK, parseError = null, status = ItemStatus.UNREAD, isFavorite = false, progress = 0f,
        progressAnchor = null, savedAt = StoreSavedAt, archivedAt = null, lastReadAt = null, source = null,
        tags = emptyList(), offline = OfflineState.DOWNLOADED, thumbnailPath = null,
    )
    SrokaTheme(darkTheme = false) {
        Box(Modifier.fillMaxSize()) {
            StoreList(dark = false)
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.32f)))
            Surface(
                modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth(),
                shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
            ) {
                Column(
                    Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 24.dp, vertical = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(20.dp),
                ) {
                    JustSaved(item = saved, onAddTags = {}, onFavorite = {}, onOpen = {})
                }
            }
        }
    }
}

private val storeSearch = listOf(
    SearchResult(
        storeItems[0], MatchIn.BOTH,
        "Magpies are known to collect shiny objects, but the story is more about curiosity than greed.",
        listOf(0..6),
    ),
    SearchResult(
        storeItems[1], MatchIn.TEXT,
        "Reading later only works when the library stays small enough to trust, like a magpie nest.",
        listOf(78..83),
    ),
    SearchResult(
        row("s10", "A field guide to corvid intelligence", "birds.example.org", 7, status = ItemStatus.ARCHIVED),
        MatchIn.TEXT, "Crows, ravens and magpies share a surprising talent for planning ahead.", listOf(18..24),
    ),
)

@PreviewTest
@Preview(name = "StorePhoneSearch", showBackground = true, device = "spec:width=360dp,height=640dp,dpi=480", apiLevel = 36)
@Composable
fun StorePhoneSearch() {
    SrokaTheme(darkTheme = false) {
        SearchContent(
            query = "magpie", scope = SearchScope.ALL, loaded = true,
            itemCount = storeSearch.size, itemAt = { storeSearch.getOrNull(it) }, itemKey = { storeSearch[it].summary.id },
            resultCount = storeSearch.size, onQueryChange = {}, onScopeChange = {}, onOpenItem = {}, onBack = {}, focus = null,
        )
    }
}

@PreviewTest
@Preview(name = "StorePhoneTags", showBackground = true, device = "spec:width=360dp,height=640dp,dpi=480", apiLevel = 36)
@Composable
fun StorePhoneTags() {
    SrokaTheme(darkTheme = false) {
        TagsContent(
            tags = storeTags, avatar = "M", selectedTag = null, navRailShown = false,
            onOpenTag = {}, onOpenSettings = {}, onRename = {}, onDelete = {},
        )
    }
}

// Google Play foldable screenshot, outer (folded) screen in portrait: 360x576dp at 480dpi renders 1080x1728 px (10:16).
@PreviewTest
@Preview(name = "StoreFoldedLibraryLight", showBackground = true, device = "spec:width=360dp,height=576dp,dpi=480", apiLevel = 36)
@Composable
fun StoreFoldedLibraryLight() = StoreList(dark = false)

@PreviewTest
@Preview(name = "StoreFoldedLibraryDark", showBackground = true, device = "spec:width=360dp,height=576dp,dpi=480", apiLevel = 36)
@Composable
fun StoreFoldedLibraryDark() = StoreList(dark = true)
