package app.sroka.feature.settings.impl

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import app.sroka.core.domain.DeleteAccountResult
import app.sroka.core.domain.RemoteFailure
import app.sroka.core.model.DownloadPolicy
import app.sroka.core.model.SessionState
import app.sroka.core.testing.fake.FakeAccountRepository
import app.sroka.core.testing.fake.FakeAuthRepository
import app.sroka.core.testing.fake.FakeContentStore
import app.sroka.core.testing.fake.FakeSettingsRepository
import app.sroka.core.testing.fake.FakeSyncController
import app.sroka.core.testing.util.MainDispatcherRule
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SettingsScreenTest {
    @get:Rule(order = 0) val mainRule = MainDispatcherRule()
    @get:Rule(order = 1) val compose = createComposeRule()

    private val auth = FakeAuthRepository(SessionState.SignedIn("me@x.io"))
    private val account = FakeAccountRepository(auth)
    private val settings = FakeSettingsRepository()
    private val content = FakeContentStore().apply { usageBytes = 2048 }
    private val sync = FakeSyncController()

    private fun show() {
        val vm = SettingsViewModel(settings, auth, account, content, sync)
        compose.setContent { SettingsRoute(onBack = {}, viewModel = vm) }
    }

    private fun tap(text: String) = compose.onNodeWithText(text).performScrollTo().performClick()

    @Test
    fun signOutAsksForConfirmationFirst() {
        show()
        compose.onNodeWithText("me@x.io").assertExists()
        tap("Sign out")
        compose.onNodeWithText("Signing out removes", substring = true).assertIsDisplayed()
        assertEquals(0, auth.signOutCount)
            compose.onNode(hasText("Sign out") and hasClickAction() and hasAnyAncestor(isDialog())).performClick()
        compose.waitForIdle()
        assertEquals(1, auth.signOutCount)
        assertEquals(SessionState.SignedOut, auth.sessionFlow.value)
    }

    @Test
    fun changingServerWarnsAboutSignOut() {
        show()
        tap("Server")
        compose.onNodeWithText("Changing the server signs you out", substring = true).assertDoesNotExist()
        compose.onNodeWithText("Server URL").performTextInput("x")
        compose.onNodeWithText("Changing the server signs you out", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Sign out and switch").assertIsDisplayed()
    }

    @Test
    fun deleteAccountRequiresTypedWord() {
        show()
        tap("Delete account")
        compose.onNode(hasText("Delete") and hasClickAction() and hasAnyAncestor(isDialog())).assertIsNotEnabled()
        compose.onNodeWithText("Type your email to confirm").performTextInput(" ME@x.io ")
        compose.onNode(hasText("Delete") and hasClickAction() and hasAnyAncestor(isDialog())).assertIsEnabled().performClick()
        compose.waitForIdle()
        assertEquals(1, account.deleteCount)
    }

    @Test
    fun rowsShowSupportingText() {
        show()
        compose.onNodeWithText("Wi-Fi only", substring = true).assertExists()
        compose.onNodeWithText("CSV or JSON").assertExists()
        compose.onNodeWithText("From Pocket and others").assertExists()
        compose.onNodeWithText("Default · 18 sp").assertExists()
    }

    @Test
    fun deleteFailureShowsMessage() {
        account.result = DeleteAccountResult.Failed(RemoteFailure.NETWORK)
        show()
        tap("Delete account")
        compose.onNodeWithText("Type your email to confirm").performTextInput(" ME@x.io ")
        compose.onNode(hasText("Delete") and hasClickAction() and hasAnyAncestor(isDialog())).performClick()
        compose.onNodeWithText("Could not delete the account", substring = true).assertIsDisplayed()
        assertEquals(SessionState.SignedIn("me@x.io"), auth.sessionFlow.value)
    }

    @Test
    fun policyDownloadAllAndRemoveDownloads() {
        show()
        tap("Offline downloads")
        compose.onNodeWithText("Manual only").performClick()
        assertEquals(DownloadPolicy.MANUAL, settings.preferencesFlow.value.downloadPolicy)
        tap("Remove downloaded articles")
        compose.onNodeWithText("Articles stay in your list", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Remove").performClick()
        compose.waitForIdle()
        assertEquals(0L, content.usageBytes)
        tap("Download all now")
        assertEquals(1, sync.fetchRequests)
    }
}
