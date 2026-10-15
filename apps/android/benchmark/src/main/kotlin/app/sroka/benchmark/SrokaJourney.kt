package app.sroka.benchmark

import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until

/** Shared helpers for macrobenchmark journeys. Extend with library/reader journeys later. */
object SrokaJourney {
    /** Measured variant (benchmarkRelease has no applicationId suffix). */
    const val PACKAGE_NAME = "app.sroka"

    private const val TIMEOUT_MS = 5_000L

    /** Waits until the first app window has content. */
    fun waitForFirstScreen(device: UiDevice) {
        device.wait(Until.hasObject(By.pkg(PACKAGE_NAME).depth(0)), TIMEOUT_MS)
        device.waitForIdle()
    }
}
