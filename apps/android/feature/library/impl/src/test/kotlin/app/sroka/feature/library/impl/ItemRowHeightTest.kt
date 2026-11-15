package app.sroka.feature.library.impl

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.theme.SrokaTheme
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.PendingChange
import app.sroka.core.model.toSummary
import app.sroka.core.testing.testItem
import app.sroka.feature.library.impl.list.ItemRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** No status, badge, star or retry button may change a row's height (same title in every state). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w360dp-h800dp-xxhdpi")
class ItemRowHeightTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun everyStateHasTheSameHeight() {
        val title = "A title long enough to sit right at the edge of the first line of the row"
        val states = listOf(
            testItem(title = title, offline = OfflineState.DOWNLOADED),
            testItem(title = title, offline = OfflineState.DOWNLOADED, isFavorite = true),
            testItem(title = title, offline = OfflineState.AVAILABLE_REMOTE),
            testItem(title = title, offline = OfflineState.DOWNLOADING),
            testItem(title = title, pendingChange = PendingChange.TAGS),
            testItem(title = title, parseStatus = ParseStatus.PARTIAL),
            testItem(title = title, parseStatus = ParseStatus.PENDING, offline = OfflineState.NONE),
            testItem(title = title, parseStatus = ParseStatus.FAILED, isFavorite = true),
            testItem(title = title, progress = 0.5f),
            testItem(title = title, progress = 1f),
        ).map { it.toSummary() }
        val heights = IntArray(states.size)
        compose.setContent {
            SrokaTheme(dynamicColor = false) {
                Column(Modifier.width(360.dp)) {
                    states.forEachIndexed { i, item ->
                        ItemRow(
                            item, onClick = {}, onLongClick = {}, onRetry = {},
                            modifier = Modifier.onGloballyPositioned { heights[i] = it.size.height },
                        )
                    }
                }
            }
        }
        compose.waitForIdle()
        assertTrue(heights.all { it > 0 })
        assertEquals(heights.toList(), List(heights.size) { heights[0] })
    }
}
