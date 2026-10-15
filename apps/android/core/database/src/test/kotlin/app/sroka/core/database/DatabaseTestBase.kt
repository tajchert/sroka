package app.sroka.core.database

import android.content.Context
import androidx.paging.PagingSource
import androidx.room3.Room
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ApplicationProvider
import app.sroka.core.database.entity.ItemEntity
import app.sroka.core.database.entity.ItemSummaryRow
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.SortOrder
import org.junit.After
import org.junit.Before
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
abstract class DatabaseTestBase {
    protected lateinit var db: SrokaDatabase

    @Before fun openDb() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        db = Room.inMemoryDatabaseBuilder<SrokaDatabase>(context).setDriver(AndroidSQLiteDriver()).build()
    }

    @After fun closeDb() = db.close()

    protected fun item(
        id: String,
        title: String? = "Title $id",
        savedAt: Long = 1_000,
        status: ItemStatus = ItemStatus.UNREAD,
        favorite: Boolean = false,
        words: Int? = 500,
        contentId: String? = "c-$id",
        excerpt: String? = null,
        archivedAt: Long? = null,
        siteName: String? = null,
    ) = ItemEntity(
        id = id, url = "https://example.com/$id", canonicalUrl = "https://example.com/$id",
        title = title, excerpt = excerpt, siteName = siteName, author = null, lang = null, leadImageKey = null,
        wordCount = words, readingMinutes = words?.let { it / 200 }, contentId = contentId,
        contentPrivate = false, parseStatus = ParseStatus.OK, parseError = null, status = status,
        isFavorite = favorite, progress = 0f, progressAnchor = null, savedAt = savedAt,
        archivedAt = archivedAt, lastReadAt = null, source = "share", serverSeq = 1,
    )

    protected suspend fun page(query: ItemQuery): List<ItemSummaryRow> {
        val source = db.itemDao().pagedItems(query)
        val result = source.load(PagingSource.LoadParams.Refresh(null, 100, false))
        return (result as PagingSource.LoadResult.Page).data
    }

    protected suspend fun ids(query: ItemQuery) = page(query).map { it.id }

    protected fun q(
        tab: LibraryTab = LibraryTab.MY_LIST,
        tag: String? = null,
        search: String? = null,
        sort: SortOrder = SortOrder.NEWEST,
    ) = ItemQuery(tab, tag, search, sort)
}
