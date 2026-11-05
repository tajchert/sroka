package app.sroka.consent

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import app.sroka.core.testing.fake.FakeConsentRepository
import app.sroka.core.testing.fake.FakeTelemetry
import app.sroka.core.testing.util.MainDispatcherRule
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ConsentPromptTest {
    @get:Rule(order = 0) val mainRule = MainDispatcherRule()
    @get:Rule(order = 1) val compose = createComposeRule()

    private val consent = FakeConsentRepository()

    private fun show(telemetry: FakeTelemetry = FakeTelemetry()) {
        val vm = ConsentPromptViewModel(consent, telemetry)
        compose.setContent { ConsentPromptHost(vm) }
    }

    @Test
    fun showsTheD15CopyOnFirstRun() {
        show()
        compose.onNodeWithText("Help improve Sroka?").assertIsDisplayed()
        compose.onNodeWithText(
            "Share anonymous usage statistics (which features are used, never what you read) via Google Analytics. " +
                "You can change this anytime in Settings.",
        ).assertIsDisplayed()
        compose.onNodeWithText("Privacy policy").assertIsDisplayed()
        compose.onNodeWithText("Allow").assertIsDisplayed()
        compose.onNodeWithText("No thanks").assertIsDisplayed()
    }

    @Test
    fun allowRecordsConsentAndHidesThePrompt() {
        show()
        compose.onNodeWithText("Allow").performClick()
        compose.waitForIdle()
        assertEquals(true, consent.consentFlow.value.analytics)
        compose.onNodeWithText("Help improve Sroka?").assertDoesNotExist()
    }

    @Test
    fun noThanksRecordsRefusalAndHidesThePrompt() {
        show()
        compose.onNodeWithText("No thanks").performClick()
        compose.waitForIdle()
        assertEquals(false, consent.consentFlow.value.analytics)
        compose.onNodeWithText("Help improve Sroka?").assertDoesNotExist()
    }

    @Test
    fun neverShownAgainOnceDecided() {
        consent.consentFlow.value = consent.consentFlow.value.copy(analytics = false)
        show()
        compose.onNodeWithText("Help improve Sroka?").assertDoesNotExist()
    }

    @Test
    fun neverShownWithoutTelemetry() {
        show(FakeTelemetry(isAvailable = false))
        compose.onNodeWithText("Help improve Sroka?").assertDoesNotExist()
    }
}
