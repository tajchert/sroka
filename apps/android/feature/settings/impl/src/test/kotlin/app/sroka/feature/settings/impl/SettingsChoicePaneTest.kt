package app.sroka.feature.settings.impl

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import app.sroka.core.model.DownloadPolicy
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.SessionState
import app.sroka.core.model.ThemeMode
import app.sroka.core.testing.fake.FakeAccountRepository
import app.sroka.core.testing.fake.FakeAuthRepository
import app.sroka.core.testing.fake.FakeContentStore
import app.sroka.core.testing.fake.FakeSettingsRepository
import app.sroka.core.testing.fake.FakeSyncController
import app.sroka.core.testing.util.MainDispatcherRule
import app.sroka.feature.settings.api.SettingsChoiceKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SettingsChoicePaneTest {
    @get:Rule(order = 0) val mainRule = MainDispatcherRule()
    @get:Rule(order = 1) val compose = createComposeRule()

    private val auth = FakeAuthRepository(SessionState.SignedIn("me@x.io"))
    private val settings = FakeSettingsRepository()

    private fun vm() = SettingsViewModel(settings, auth, FakeAccountRepository(auth), FakeContentStore(), FakeSyncController())

    private fun showChoice(kind: SettingsChoiceKind) {
        val vm = vm()
        compose.setContent { SettingsChoiceRoute(kind, vm) }
    }

    @Test
    fun themePageAppliesChoiceAndStaysOpen() {
        showChoice(SettingsChoiceKind.Theme)
        compose.onNodeWithText("Dark").performClick()
        assertEquals(ThemeMode.DARK, settings.preferencesFlow.value.themeMode)
        compose.onNodeWithText("Light").assertIsDisplayed()
    }

    @Test
    fun readerThemeAndOfflinePagesApplyChoices() {
        showChoice(SettingsChoiceKind.ReaderTheme)
        compose.onNodeWithText("Sepia").performClick()
        assertEquals(ReaderTheme.SEPIA, settings.preferencesFlow.value.readerTheme)
    }

    @Test
    fun offlinePageApplies() {
        showChoice(SettingsChoiceKind.Offline)
        compose.onNodeWithText("Manual only").performClick()
        assertEquals(DownloadPolicy.MANUAL, settings.preferencesFlow.value.downloadPolicy)
    }

    @Test
    fun textSizePageOffersAllSteps() {
        showChoice(SettingsChoiceKind.TextSize)
        compose.onNodeWithText("Default · 18 sp").assertIsDisplayed()
        compose.onNodeWithText("29 sp", substring = true).performScrollTo().performClick()
        assertEquals(1.6f, settings.preferencesFlow.value.readerTextScale, 0.001f)
    }

    @Test
    fun serverPageWarnsWhenSwitching() {
        showChoice(SettingsChoiceKind.Server)
        compose.onNodeWithText("Changing the server signs you out", substring = true).assertDoesNotExist()
        compose.onNodeWithText("Server URL").performTextInput("x")
        compose.onNodeWithText("Changing the server signs you out", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Sign out and switch").assertIsDisplayed()
    }

    @Test
    fun twoPaneRowOpensChoicePageInsteadOfDialog() {
        val vm = vm()
        var opened: SettingsChoiceKind? = null
        compose.setContent {
            SettingsRoute(onBack = {}, twoPane = true, onOpenChoice = { opened = it }, viewModel = vm)
        }
        compose.onNodeWithText("Theme").performScrollTo().performClick()
        assertEquals(SettingsChoiceKind.Theme, opened)
        compose.onAllNodes(isDialog()).fetchSemanticsNodes().let { assertTrue(it.isEmpty()) }
    }

    @Test
    fun phoneRowStillOpensDialog() {
        val vm = vm()
        var opened = false
        compose.setContent { SettingsRoute(onBack = {}, onOpenChoice = { opened = true }, viewModel = vm) }
        compose.onNodeWithText("Theme").performScrollTo().performClick()
        assertFalse(opened)
        compose.onNode(hasText("Cancel")).assertIsDisplayed()
    }

    @Test
    fun serverSwitchDetection() {
        assertFalse(isServerSwitch("", "https://a.io"))
        assertFalse(isServerSwitch(" https://a.io/ ", "https://a.io"))
        assertTrue(isServerSwitch("https://b.io", "https://a.io"))
    }
}
