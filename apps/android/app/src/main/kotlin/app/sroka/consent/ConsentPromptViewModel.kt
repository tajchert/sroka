package app.sroka.consent

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.sroka.core.domain.ConsentRepository
import app.sroka.core.domain.Telemetry
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class ConsentPromptViewModel @Inject constructor(
    private val consent: ConsentRepository,
    private val telemetry: Telemetry,
) : ViewModel() {

    /** True until the user decided; never in builds without telemetry (foss, or no Firebase config). */
    val showPrompt: StateFlow<Boolean> = consent.consent
        .map { telemetry.isAvailable && it.analytics == null }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), false)

    fun decide(allow: Boolean) {
        viewModelScope.launch { consent.setAnalytics(allow) }
    }
}
