package app.sroka.feature.auth.impl

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import app.sroka.core.domain.AuthError
import app.sroka.core.domain.AuthResult
import app.sroka.core.model.SessionState
import app.sroka.core.testing.fake.FakeAuthRepository
import app.sroka.core.testing.fake.FakeSettingsRepository
import app.sroka.core.testing.util.MainDispatcherRule
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AuthScreenTest {
    @get:Rule(order = 0) val mainRule = MainDispatcherRule()
    @get:Rule(order = 1) val compose = createComposeRule()

    private val auth = FakeAuthRepository()
    private val settings = FakeSettingsRepository()

    private fun setContent(vm: AuthViewModel = AuthViewModel(auth, settings)): AuthViewModel {
        compose.setContent { AuthRoute(vm) }
        return vm
    }

    private fun toCodeStep() {
        compose.onNodeWithText("Email").performTextInput("a@b.co")
        compose.onNodeWithText("Send code").performClick()
    }

    @Test
    fun codeAutoSubmitsAtSixDigits() {
        val vm = setContent()
        toCodeStep()
        compose.onNodeWithText("6-digit code").assertIsDisplayed()
        compose.onNodeWithText("6-digit code").performTextInput("123456")
        compose.waitForIdle()
        assertEquals(SessionState.SignedIn("a@b.co"), auth.sessionFlow.value)
        assertEquals(listOf("a@b.co"), auth.sentCodesTo)
        assertEquals(false, vm.state.value.loading)
    }

    @Test
    fun invalidCodeShowsErrorAndClearsField() {
        auth.signInResult = AuthResult.Failure(AuthError.InvalidCode)
        setContent()
        toCodeStep()
        compose.onNodeWithText("6-digit code").performTextInput("000000")
        compose.onNodeWithText("That code is not correct. Try again.").assertIsDisplayed()
        assertEquals(SessionState.SignedOut, auth.sessionFlow.value)
    }

    @Test
    fun rateLimitedShowsSeconds() {
        auth.sendCodeResult = AuthResult.Failure(AuthError.RateLimited(30))
        setContent()
        toCodeStep()
        compose.onNodeWithText("Too many requests. Try again in 30 seconds.").assertIsDisplayed()
    }

    @Test
    fun expiredSessionPrefillsEmail() {
        val expired = FakeAuthRepository(SessionState.Expired("me@x.io"))
        val vm = AuthViewModel(expired, settings)
        setContent(vm)
        assertEquals("me@x.io", vm.state.value.email)
    }

    @Test
    fun invalidServerUrlRejected() {
        val vm = setContent()
        vm.saveServerUrl("ftp://nope")
        assertEquals(true, vm.state.value.serverUrlInvalid)
        vm.saveServerUrl("https://my.server")
        assertEquals("https://my.server", settings.preferencesFlow.value.serverUrl)
    }
}
