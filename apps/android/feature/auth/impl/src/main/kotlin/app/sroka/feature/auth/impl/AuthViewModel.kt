package app.sroka.feature.auth.impl

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.sroka.core.domain.AuthError
import app.sroka.core.domain.AuthRepository
import app.sroka.core.domain.AuthResult
import app.sroka.core.domain.SettingsRepository
import app.sroka.core.model.SessionState
import app.sroka.core.model.UrlNormalizer
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

const val CODE_LENGTH = 6
const val RESEND_COOLDOWN_SECONDS = 60

enum class AuthStep { EMAIL, CODE }

data class AuthUiState(
    val step: AuthStep = AuthStep.EMAIL,
    val email: String = "",
    val code: String = "",
    val loading: Boolean = false,
    val error: AuthError? = null,
    val resendSeconds: Int = 0,
    /** Effective server URL shown in the advanced dialog. */
    val serverUrl: String = "",
    val serverDialogOpen: Boolean = false,
    val serverUrlInvalid: Boolean = false,
)

@HiltViewModel
class AuthViewModel @Inject constructor(
    private val auth: AuthRepository,
    private val settings: SettingsRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(AuthUiState(serverUrl = settings.defaultServerUrl))
    val state: StateFlow<AuthUiState> = _state.asStateFlow()

    private var cooldownJob: Job? = null

    init {
        viewModelScope.launch {
            // Re-sign-in: prefill the email of an expired session.
            (auth.session.first() as? SessionState.Expired)?.let { s ->
                _state.update { if (it.email.isEmpty()) it.copy(email = s.email) else it }
            }
            val custom = settings.preferences.first().serverUrl
            _state.update { it.copy(serverUrl = custom ?: settings.defaultServerUrl) }
        }
    }

    fun onEmailChange(value: String) = _state.update { it.copy(email = value, error = null) }

    fun onCodeChange(value: String) {
        val digits = value.filter { it.isDigit() }.take(CODE_LENGTH)
        if (_state.value.loading) return
        _state.update { it.copy(code = digits, error = null) }
        if (digits.length == CODE_LENGTH) submitCode()
    }

    fun sendCode() {
        val s = _state.value
        val email = s.email.trim()
        if (s.loading) return
        if (!EMAIL_REGEX.matches(email)) {
            _state.update { it.copy(error = AuthError.InvalidEmail) }
            return
        }
        _state.update { it.copy(loading = true, error = null, email = email) }
        viewModelScope.launch { handleSend(auth.sendCode(email), moveToCode = true) }
    }

    fun resend() {
        val s = _state.value
        if (s.loading || s.resendSeconds > 0) return
        _state.update { it.copy(loading = true, error = null, code = "") }
        viewModelScope.launch { handleSend(auth.sendCode(s.email), moveToCode = false) }
    }

    private fun handleSend(result: AuthResult, moveToCode: Boolean) {
        when (result) {
            AuthResult.Success -> {
                _state.update { it.copy(loading = false, step = AuthStep.CODE, code = "") }
                startCooldown(RESEND_COOLDOWN_SECONDS)
            }
            is AuthResult.Failure -> {
                val e = result.error
                _state.update { it.copy(loading = false, error = e) }
                if (!moveToCode && e is AuthError.RateLimited) {
                    startCooldown((e.retryAfterSeconds ?: RESEND_COOLDOWN_SECONDS.toLong()).toInt())
                }
            }
        }
    }

    private fun submitCode() {
        val s = _state.value
        if (s.loading || s.code.length != CODE_LENGTH) return
        _state.update { it.copy(loading = true, error = null) }
        viewModelScope.launch {
            when (val result = auth.signIn(s.email, s.code)) {
                // The app observes the session and leaves this screen.
                AuthResult.Success -> _state.update { it.copy(loading = false) }
                is AuthResult.Failure -> {
                    val clear = result.error !is AuthError.Network && result.error !is AuthError.Server
                    _state.update {
                        it.copy(loading = false, error = result.error, code = if (clear) "" else it.code)
                    }
                }
            }
        }
    }

    /** Back from the code step to the email step. */
    fun changeEmail() {
        cooldownJob?.cancel()
        _state.update { it.copy(step = AuthStep.EMAIL, code = "", error = null, resendSeconds = 0) }
    }

    private fun startCooldown(seconds: Int) {
        cooldownJob?.cancel()
        cooldownJob = viewModelScope.launch {
            for (left in seconds downTo 1) {
                _state.update { it.copy(resendSeconds = left) }
                delay(1_000)
            }
            _state.update { it.copy(resendSeconds = 0) }
        }
    }

    fun openServerDialog() = _state.update { it.copy(serverDialogOpen = true, serverUrlInvalid = false) }

    fun dismissServerDialog() = _state.update { it.copy(serverDialogOpen = false) }

    /** Saves a custom server URL; blank restores the default. */
    fun saveServerUrl(input: String) {
        val url = input.trim()
        if (url.isNotEmpty() && !UrlNormalizer.isHttpUrl(url)) {
            _state.update { it.copy(serverUrlInvalid = true) }
            return
        }
        viewModelScope.launch {
            val ok = settings.setServerUrl(url.ifEmpty { null })
            _state.update {
                if (ok) {
                    it.copy(
                        serverDialogOpen = false,
                        serverUrlInvalid = false,
                        serverUrl = url.ifEmpty { settings.defaultServerUrl },
                    )
                } else {
                    it.copy(serverUrlInvalid = true)
                }
            }
        }
    }

    private companion object {
        val EMAIL_REGEX = Regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")
    }
}
