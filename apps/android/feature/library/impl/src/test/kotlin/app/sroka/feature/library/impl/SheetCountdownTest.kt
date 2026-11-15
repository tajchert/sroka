package app.sroka.feature.library.impl

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import app.sroka.core.designsystem.theme.SrokaTheme
import app.sroka.feature.library.impl.save.COUNTDOWN_LINE_TAG
import app.sroka.feature.library.impl.save.CountdownDragHandle
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SheetCountdownTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun lineShowsWhileRunningAndVanishesWhenStopped() {
        var running by mutableStateOf(true)
        compose.setContent { SrokaTheme { CountdownDragHandle(running = running, durationMs = 4_000L) } }
        compose.onNodeWithTag(COUNTDOWN_LINE_TAG).assertIsDisplayed()
        running = false
        compose.waitForIdle()
        compose.onNodeWithTag(COUNTDOWN_LINE_TAG).assertDoesNotExist()
    }

    @Test
    fun touchOnTheHandleIsReported() {
        var presses = 0
        compose.setContent {
            SrokaTheme { CountdownDragHandle(running = true, durationMs = 4_000L, onPress = { presses++ }) }
        }
        compose.onNodeWithTag(COUNTDOWN_LINE_TAG).performTouchInput { down(center) }
        compose.waitForIdle()
        assertEquals(true, presses > 0)
    }
}
