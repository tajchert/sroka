package app.sroka.feature.library.impl.save

import android.provider.Settings
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp

internal const val COUNTDOWN_LINE_TAG = "share_countdown_line"

/** Runs [onPress] on any finger-down, before the children see it, without consuming the event. */
internal fun Modifier.onAnyPress(onPress: () -> Unit): Modifier = pointerInput(Unit) {
    awaitPointerEventScope {
        while (true) {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            if (event.changes.any { it.pressed }) onPress()
        }
    }
}

/**
 * The sheet's standard drag handle with a thin brand-coloured line along its very top edge that shrinks from the
 * full width to nothing over [durationMs] while [running]. The handle sits inside the sheet's clipped surface, so
 * the line follows the rounded top corners. Whoever owns the timer drives [running] (single source of truth); the
 * line disappears the moment it turns false.
 *
 * With system animations off the line stays static at full width instead of animating.
 *
 * @param startFraction share of [durationMs] still left when the animation starts; lets a recreated sheet resume
 * @param restartKey a new value restarts the animation while [running] stays true
 * @param onPress called on any touch of the handle (drags included)
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CountdownDragHandle(
    running: Boolean,
    durationMs: Long,
    modifier: Modifier = Modifier,
    startFraction: () -> Float = { 1f },
    restartKey: Any? = null,
    onPress: () -> Unit = {},
) {
    val animationsOff = rememberAnimationsOff()
    val fraction = remember { Animatable(1f) }
    LaunchedEffect(running, restartKey, animationsOff) {
        if (running && !animationsOff) {
            val from = startFraction()
            fraction.snapTo(from)
            fraction.animateTo(0f, tween((durationMs * from).toInt(), easing = LinearEasing))
        } else {
            fraction.snapTo(1f)
        }
    }
    Box(modifier.fillMaxWidth().onAnyPress(onPress)) {
        BottomSheetDefaults.DragHandle(Modifier.align(Alignment.Center))
        if (running) {
            Box(
                Modifier
                    .align(Alignment.TopCenter)
                    .testTag(COUNTDOWN_LINE_TAG)
                    .fillMaxWidth()
                    .height(3.dp)
                    // Read in the layer block: the animation redraws only, it does not recompose.
                    .graphicsLayer { scaleX = fraction.value }
                    .background(MaterialTheme.colorScheme.primary),
            )
        }
    }
}

/** True when the user turned "Remove animations" on (animator duration scale 0). */
@Composable
private fun rememberAnimationsOff(): Boolean {
    val resolver = LocalContext.current.contentResolver
    return remember(resolver) {
        runCatching { Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
            .getOrDefault(false)
    }
}
