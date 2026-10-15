package app.sroka.core.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.widget.Toast
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.net.toUri

/** Opens an http(s) link in a Custom Tab. Any other scheme is ignored (untrusted item/article URLs). */
fun openExternalLink(context: Context, url: String) {
    val uri = url.toUri()
    val scheme = uri.scheme?.lowercase()
    if (scheme != "http" && scheme != "https") return
    try {
        CustomTabsIntent.Builder().build().launchUrl(context, uri)
    } catch (_: ActivityNotFoundException) {
        Toast.makeText(context, R.string.core_ui_no_browser, Toast.LENGTH_SHORT).show()
    }
}
