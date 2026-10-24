package app.sroka.feature.settings.impl

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.sroka.core.domain.AccountRepository
import app.sroka.core.domain.AuthRepository
import app.sroka.core.domain.ContentStore
import app.sroka.core.domain.DeleteAccountResult
import app.sroka.core.domain.SettingsRepository
import app.sroka.core.domain.SyncController
import app.sroka.core.model.DownloadPolicy
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.SessionState
import app.sroka.core.model.ThemeMode
import app.sroka.core.model.UrlNormalizer
import app.sroka.core.model.UserPreferences
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/** One-shot messages shown as snackbars. */
enum class SettingsMessage { FetchStarted, DownloadsRemoved, DeleteFailed, ServerSaved }

data class SettingsUiState(
    val preferences: UserPreferences = UserPreferences(),
    val email: String? = null,
    val storageBytes: Long = 0,
    val serverUrl: String = "",
    val serverUrlInvalid: Boolean = false,
    val busy: Boolean = false,
)

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settings: SettingsRepository,
    private val auth: AuthRepository,
    private val account: AccountRepository,
    private val content: ContentStore,
    private val sync: SyncController,
) : ViewModel() {

    private val storage = MutableStateFlow(0L)
    private val local = MutableStateFlow(LocalState())
    private val messageChannel = Channel<SettingsMessage>(Channel.BUFFERED)
    val messages: Flow<SettingsMessage> = messageChannel.receiveAsFlow()

    private data class LocalState(val busy: Boolean = false, val serverUrlInvalid: Boolean = false)

    val state: StateFlow<SettingsUiState> = combine(
        settings.preferences,
        auth.session,
        storage,
        local,
    ) { prefs, session, bytes, loc ->
        SettingsUiState(
            preferences = prefs,
            email = when (session) {
                is SessionState.SignedIn -> session.email
                is SessionState.Expired -> session.email
                SessionState.SignedOut -> null
            },
            storageBytes = bytes,
            serverUrl = prefs.serverUrl ?: settings.defaultServerUrl,
            serverUrlInvalid = loc.serverUrlInvalid,
            busy = loc.busy,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SettingsUiState())

    init {
        refreshStorage()
    }

    fun refreshStorage() {
        viewModelScope.launch { storage.value = content.storageUsageBytes() }
    }

    fun setDownloadPolicy(policy: DownloadPolicy) = viewModelScope.launch { settings.setDownloadPolicy(policy) }

    fun setThemeMode(mode: ThemeMode) = viewModelScope.launch { settings.setThemeMode(mode) }

    fun setReaderTheme(theme: ReaderTheme) = viewModelScope.launch { settings.setReaderTheme(theme) }

    fun setReaderTextScale(scale: Float) = viewModelScope.launch { settings.setReaderTextScale(scale) }

    fun downloadAllNow() {
        sync.fetchNewArticles()
        messageChannel.trySend(SettingsMessage.FetchStarted)
    }

    fun removeDownloads() {
        viewModelScope.launch {
            content.clearDownloads()
            storage.value = content.storageUsageBytes()
            messageChannel.send(SettingsMessage.DownloadsRemoved)
        }
    }

    /** The session change navigates the app to sign-in. */
    fun signOut() {
        viewModelScope.launch { runBusy { auth.signOut() } }
    }

    fun deleteAccount() {
        viewModelScope.launch {
            runBusy {
                if (account.deleteAccount() is DeleteAccountResult.Failed) {
                    messageChannel.send(SettingsMessage.DeleteFailed)
                }
            }
        }
    }

    /** Saves a custom server URL; blank restores the default. Returns true when accepted. */
    fun saveServerUrl(input: String, onDone: () -> Unit) {
        val url = input.trim()
        if (url.isNotEmpty() && !UrlNormalizer.isHttpUrl(url)) {
            local.update { it.copy(serverUrlInvalid = true) }
            return
        }
        viewModelScope.launch {
            if (settings.setServerUrl(url.ifEmpty { null })) {
                local.update { it.copy(serverUrlInvalid = false) }
                messageChannel.send(SettingsMessage.ServerSaved)
                onDone()
            } else {
                local.update { it.copy(serverUrlInvalid = true) }
            }
        }
    }

    fun clearServerError() = local.update { it.copy(serverUrlInvalid = false) }

    private suspend fun runBusy(block: suspend () -> Unit) {
        local.update { it.copy(busy = true) }
        try {
            block()
        } finally {
            local.update { it.copy(busy = false) }
        }
    }
}
