package app.sroka.navigation

import androidx.lifecycle.ViewModel
import app.sroka.core.domain.Telemetry
import app.sroka.core.domain.TelemetryEvent
import app.sroka.core.domain.TelemetryScreen
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject

/** Reports `screen_view` (D15); the enum is the only thing that leaves the app. */
@HiltViewModel
class ScreenTrackerViewModel @Inject constructor(
    private val telemetry: Telemetry,
) : ViewModel() {
    fun screenShown(screen: TelemetryScreen) = telemetry.logEvent(TelemetryEvent.ScreenView(screen))
}
