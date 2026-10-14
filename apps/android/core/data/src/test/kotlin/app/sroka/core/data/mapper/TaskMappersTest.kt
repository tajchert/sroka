package app.sroka.core.data.mapper

import app.sroka.core.database.entity.toEntity
import app.sroka.core.database.entity.toModel
import app.sroka.core.model.Task
import app.sroka.core.model.TaskPriority
import kotlin.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Test

class TaskMappersTest {

    @Test
    fun `database round trip preserves task`() {
        val task = Task(
            id = "task-1",
            title = "Ship safely",
            description = "Protect persistence contracts",
            isCompleted = true,
            createdAt = Instant.parse("2026-07-11T10:15:30.123Z"),
            priority = TaskPriority.HIGH,
        )

        assertEquals(task, task.toEntity().toModel())
    }

    @Test
    fun `network mapping normalizes priority`() {
        val entity = app.sroka.core.network.dto.NetworkTask(
            id = "task-2",
            title = "Map data",
            description = "",
            isCompleted = false,
            createdAt = "2026-07-11T10:15:30Z",
            priority = "low",
        ).toEntity()

        assertEquals("LOW", entity.priority)
        assertEquals(Instant.parse("2026-07-11T10:15:30Z"), entity.toModel().createdAt)
    }
}
