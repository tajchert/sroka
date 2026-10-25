package app.sroka.core.designsystem.component

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Widest a settings-style page or list column gets on tablets and unfolded foldables. */
val ReadableMaxWidth: Dp = 640.dp

/**
 * Fills the width up to [max] and centres the content in anything wider; phones are unaffected.
 * Put it after `verticalScroll` so the whole width still scrolls.
 */
fun Modifier.readableWidth(max: Dp = ReadableMaxWidth): Modifier =
    fillMaxWidth().wrapContentWidth(Alignment.CenterHorizontally).widthIn(max = max).fillMaxWidth()
