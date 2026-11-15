package app.sroka.core.database

import app.sroka.core.database.dao.itemListSql
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SortOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ItemListSqlTest {

    @Test fun plainTabHasOneConcreteConditionAndNoArgs() {
        val built = itemListSql(ItemQuery(LibraryTab.MY_LIST))
        assertTrue(built.sql.contains("FROM items i LEFT JOIN content_files cf"))
        assertTrue(built.sql.contains("WHERE i.status = 'UNREAD' ORDER BY i.saved_at DESC"))
        assertEquals(emptyList<Any>(), built.args)
    }

    @Test fun everyFilterAddsAnAndConditionWithBoundArgsInOrder() {
        val built = itemListSql(
            ItemQuery(
                tab = LibraryTab.ARCHIVE,
                tag = " News ",
                search = "cats",
                sort = SortOrder.SHORTEST,
                favoritesOnly = true,
                maxReadingMinutes = 9,
            ),
        )
        assertTrue(built.sql.contains("FROM items_fts JOIN items i ON i.fts_rowid = items_fts.rowid JOIN item_tags t"))
        assertTrue(
            built.sql.contains(
                "WHERE items_fts MATCH ? AND t.name_key = ? AND i.status = 'ARCHIVED' AND i.is_favorite = 1 " +
                    "AND i.reading_minutes IS NOT NULL AND i.reading_minutes <= ?",
            ),
        )
        assertTrue(built.sql.endsWith("ORDER BY (i.word_count IS NULL), i.word_count ASC, i.saved_at DESC, i.id DESC"))
        assertEquals(3, built.args.size)
        assertEquals("news", built.args[1])
        assertEquals(9L, built.args[2])
        assertFalse(built.sql.contains(" OR "))
    }

    @Test fun tagPageWithoutTabIsDrivenByTheTagIndex() {
        val built = itemListSql(ItemQuery(tab = null, tag = "x"))
        assertTrue(built.sql.contains("FROM item_tags t JOIN items i ON i.id = t.item_id"))
        assertTrue(built.sql.contains("WHERE t.name_key = ? ORDER BY"))
    }

    @Test fun symbolOnlySearchIsIgnoredAndFavoritesTabNeedsNoSecondCondition() {
        val built = itemListSql(ItemQuery(LibraryTab.FAVORITES, search = "***", favoritesOnly = true))
        assertFalse(built.sql.contains("MATCH"))
        assertEquals(1, Regex("is_favorite = 1").findAll(built.sql).count())
    }
}
