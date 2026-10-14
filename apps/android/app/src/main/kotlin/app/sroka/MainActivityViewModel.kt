package app.sroka

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.sroka.core.domain.AuthRepository
import app.sroka.core.domain.SettingsRepository
import app.sroka.core.model.SessionState
import app.sroka.core.model.ThemeMode
import app.sroka.core.model.UserPreferences
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import javax.inject.Inject

/** What MainActivity needs before showing any screen: theme preferences and the session. */
sealed interface MainActivityUiState {
    /** Still loading: keep the splash screen. */
    data object Loading : MainActivityUiState

    data class Success(
        val preferences: UserPreferences,
        val session: SessionState,
    ) : MainActivityUiState {
        /** Expired sessions keep the library visible (with a "sign in again" banner). */
        val isSignedIn: Boolean get() = session !is SessionState.SignedOut
    }
}

@HiltViewModel
class MainActivityViewModel @Inject constructor(
    settingsRepository: SettingsRepository,
    authRepository: AuthRepository,
) : ViewModel() {

    val uiState: StateFlow<MainActivityUiState> = combine(
        settingsRepository.preferences,
        authRepository.session,
    ) { preferences, session -> MainActivityUiState.Success(preferences, session) }
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5_000),
            initialValue = MainActivityUiState.Loading,
        )
}

/** Dark theme per the stored [ThemeMode]; while loading, follow the system. */
fun MainActivityUiState.shouldUseDarkTheme(isSystemInDarkTheme: Boolean): Boolean = when (this) {
    MainActivityUiState.Loading -> isSystemInDarkTheme
    is MainActivityUiState.Success -> when (preferences.themeMode) {
        ThemeMode.SYSTEM -> isSystemInDarkTheme
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
    }
}

/** Dynamic color per preferences; loading uses the stable app palette. */
fun MainActivityUiState.shouldUseDynamicColor(): Boolean =
    this is MainActivityUiState.Success && preferences.dynamicColor
