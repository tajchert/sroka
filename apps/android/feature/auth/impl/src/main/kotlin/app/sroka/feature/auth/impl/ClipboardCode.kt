package app.sroka.feature.auth.impl

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

/**
 * The sign-in code in [text] when it is exactly [CODE_LENGTH] ASCII digits, optionally surrounded by
 * whitespace. Anything else (grouped digits, a longer number, prose) is not offered for pasting.
 */
internal fun parseClipboardCode(text: CharSequence?): String? {
    val trimmed = text?.toString()?.trim() ?: return null
    return trimmed.takeIf { it.length == CODE_LENGTH && it.all { c -> c in '0'..'9' } }
}

/**
 * The code on the primary clip, or null. The MIME type is checked on the description first, so non-text clips
 * (images, files) are never read. Only text items are read, never URI contents. The clip is never logged.
 */
internal fun ClipboardManager.primaryClipCode(): String? {
    val description = primaryClipDescription ?: return null
    if (!description.hasMimeType("text/*")) return null
    val clip = primaryClip ?: return null
    if (clip.itemCount < 1) return null
    return parseClipboardCode(clip.getItemAt(0).text)
}

/**
 * The 6-digit code currently on the clipboard while [enabled] and the screen is resumed and focused (Android 10+
 * only lets the focused app read the clipboard), else null. Re-read on resume, on focus and when the clip changes.
 */
@Composable
internal fun rememberClipboardCode(enabled: Boolean): String? {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val focused = LocalWindowInfo.current.isWindowFocused
    var code by remember { mutableStateOf<String?>(null) }
    DisposableEffect(context, lifecycle, enabled, focused) {
        val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        fun refresh() {
            code = if (enabled && focused && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
                runCatching { manager?.primaryClipCode() }.getOrNull()
            } else {
                null
            }
        }
        val clipListener = ClipboardManager.OnPrimaryClipChangedListener { refresh() }
        val observer = LifecycleEventObserver { _, _ -> refresh() }
        refresh()
        manager?.addPrimaryClipChangedListener(clipListener)
        lifecycle.addObserver(observer)
        onDispose {
            manager?.removePrimaryClipChangedListener(clipListener)
            lifecycle.removeObserver(observer)
        }
    }
    return code
}
