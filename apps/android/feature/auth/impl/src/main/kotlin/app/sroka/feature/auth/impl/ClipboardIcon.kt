package app.sroka.feature.auth.impl

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.graphics.vector.group
import androidx.compose.ui.unit.dp

/**
 * Material Symbols Rounded `content_paste`, in the same form `scripts/gen-icons.py` emits. It lives here
 * until it is added to `SrokaIcons` (core:designsystem), which this module does not own.
 */
internal val ClipboardIcon: ImageVector by lazy {
    ImageVector.Builder("ContentPaste", 24.dp, 24.dp, viewportWidth = 960f, viewportHeight = 960f, autoMirror = false).apply {
        group(translationY = 960f) {
            addPath(PathParser().parsePathString("M200-120q-33 0-56.5-23.5T120-200v-560q0-33 23.5-56.5T200-840h167q11-35 43-57.5t70-22.5q40 0 71.5 22.5T594-840h166q33 0 56.5 23.5T840-760v560q0 33-23.5 56.5T760-120H200Zm0-80h560v-560h-80v80q0 17-11.5 28.5T640-640H320q-17 0-28.5-11.5T280-680v-80h-80v560Zm308.5-571.5Q520-783 520-800t-11.5-28.5Q497-840 480-840t-28.5 11.5Q440-817 440-800t11.5 28.5Q463-760 480-760t28.5-11.5Z").toNodes(), fill = SolidColor(Color.Black))
        }
    }.build()
}
