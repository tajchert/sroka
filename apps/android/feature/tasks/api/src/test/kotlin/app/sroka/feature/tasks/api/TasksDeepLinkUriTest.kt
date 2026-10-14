package app.sroka.feature.tasks.api

import android.net.Uri
import androidx.core.net.toUri
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Covers URI ownership, decoded arguments, and route precedence. */
@RunWith(RobolectricTestRunner::class)
class TasksDeepLinkUriTest {

    @Test
    fun `a verified web link resolves`() {
        assertEquals(
            listOf(TaskListRoute, TaskDetailRoute(taskId = "abc-123")),
            TasksDeepLinks.resolve("https://sroka.app/tasks/abc-123".toUri()),
        )
    }

    @Test
    fun `the custom scheme resolves to the same back stack`() {
        assertEquals(
            listOf(TaskListRoute, TaskDetailRoute(taskId = "abc-123")),
            TasksDeepLinks.resolve("sroka://tasks/abc-123".toUri()),
        )
    }

    @Test
    fun `scheme and host are matched case insensitively`() {
        assertEquals(
            listOf(TaskListRoute),
            TasksDeepLinks.resolve("HTTPS://SROKA.APP/tasks".toUri()),
        )
    }

    @Test
    fun `a link for another host is not ours`() {
        // A lookalike host is the obvious attack on a URI allowlist, so the
        // host is compared exactly rather than by suffix or prefix.
        assertNull(TasksDeepLinks.resolve("https://sroka.app.evil.test/tasks".toUri()))
        assertNull(TasksDeepLinks.resolve("https://evil.test/tasks".toUri()))
        assertNull(TasksDeepLinks.resolve("https://sub.sroka.app/tasks".toUri()))
    }

    @Test
    fun `a web link outside the tasks prefix is not ours`() {
        assertNull(TasksDeepLinks.resolve("https://sroka.app/".toUri()))
        assertNull(TasksDeepLinks.resolve("https://sroka.app/admin".toUri()))
    }

    @Test
    fun `an unrelated scheme is not ours`() {
        assertNull(TasksDeepLinks.resolve("file:///etc/passwd".toUri()))
        assertNull(TasksDeepLinks.resolve("javascript:alert(1)".toUri()))
        assertNull(TasksDeepLinks.resolve("other-app://tasks/abc-123".toUri()))
    }

    @Test
    fun `a missing uri is not ours`() {
        // An Intent with no data must never navigate anywhere special.
        assertNull(TasksDeepLinks.resolve(null))
    }
    @Test
    fun `encoded reserved new segment opens create rather than detail`() {
        assertEquals(
            listOf(TaskListRoute, CreateTaskRoute),
            TasksDeepLinks.resolve("https://sroka.app/tasks/%6Eew".toUri()),
        )
    }

    @Test
    fun `encoded separators and traversal do not become task ids`() {
        listOf("%2F", "%2e%2e", "abc%2Fdef", "%252e%252e", "id%20with%20spaces")
            .forEach { id ->
                assertNull(id, TasksDeepLinks.resolve("https://sroka.app/tasks/$id".toUri()))
            }
    }

    @Test
    fun `query arguments cannot override the path task id`() {
        assertEquals(
            listOf(TaskListRoute, TaskDetailRoute("abc-123")),
            TasksDeepLinks.resolve("https://sroka.app/tasks/abc-123?taskId=other".toUri()),
        )
    }

    @Test
    fun `encoded valid id is decoded once`() {
        assertEquals(
            listOf(TaskListRoute, TaskDetailRoute("abc-123")),
            TasksDeepLinks.resolve("https://sroka.app/tasks/abc%2D123".toUri()),
        )
    }
    @Test
    fun `only declared schemes and authorities are accepted`() {
        listOf(
            "http://sroka.app/tasks/abc-123",
            "https://sroka.app:8443/tasks/abc-123",
            "https://user@sroka.app/tasks/abc-123",
            "sroka://sroka.app/abc-123",
            "https://tasks/abc-123",
        ).forEach { link -> assertNull(link, TasksDeepLinks.resolve(link.toUri())) }
    }

    @Test
    fun `empty and trailing path segments are rejected`() {
        listOf(
            "https://sroka.app/tasks/",
            "https://sroka.app/tasks//abc-123",
            "https://sroka.app/tasks/abc-123/",
            "sroka://tasks/abc-123/",
        ).forEach { link -> assertNull(link, TasksDeepLinks.resolve(link.toUri())) }
    }
    @Test
    fun `literal path components are case sensitive and ids retain case`() {
        assertNull(TasksDeepLinks.resolve("https://sroka.app/TASKS".toUri()))
        assertNull(TasksDeepLinks.resolve("https://sroka.app/Tasks/new".toUri()))
        listOf("NEW", "%4Eew").forEach { id ->
            assertEquals(
                listOf(TaskListRoute, TaskDetailRoute(Uri.decode(id))),
                TasksDeepLinks.resolve("https://sroka.app/tasks/$id".toUri()),
            )
        }
    }
}
