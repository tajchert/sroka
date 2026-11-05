package app.sroka.core.data.telemetry

import app.sroka.core.domain.SaveSource
import app.sroka.core.model.ItemStatus
import app.sroka.core.testing.fake.FakeLibraryRepository
import app.sroka.core.testing.fake.FakeTelemetry
import app.sroka.core.testing.testItem
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class TelemetryLibraryRepositoryTest {

    private val fake = FakeLibraryRepository(listOf(testItem(id = "a", tags = listOf("x"))))
    private val telemetry = FakeTelemetry()
    private val repo = TelemetryLibraryRepository(fake, telemetry)

    @Test
    fun reportsEventsWithEnumParamsOnly() = runTest {
        repo.save("https://example.com/secret-path", source = SaveSource.DRAG)
        repo.setStatus("a", ItemStatus.ARCHIVED)
        repo.setStatus("a", ItemStatus.UNREAD)
        repo.setFavorite("a", true)
        repo.delete("a")

        assertEquals(
            listOf("save_item", "archive_item", "unarchive_item", "favorite_item", "delete_item"),
            telemetry.eventNames,
        )
        assertEquals(mapOf("source" to "drag", "kind" to "article"), telemetry.events[0].params)
        assertEquals(mapOf("on" to "true"), telemetry.events[3].params)
        // Nothing user-specific anywhere in the reported values.
        telemetry.events.flatMap { it.params.values }.forEach {
            assert(!it.contains("secret") && !it.contains("example.com") && it != "a")
        }
    }

    @Test
    fun addTagOnlyWhenANewTagAppears() = runTest {
        repo.setTags("a", listOf("x"))
        repo.setTags("a", emptyList())
        assertEquals(emptyList<String>(), telemetry.eventNames)
        repo.setTags("a", listOf("x", "new"))
        assertEquals(listOf("add_tag"), telemetry.eventNames)
    }
}
