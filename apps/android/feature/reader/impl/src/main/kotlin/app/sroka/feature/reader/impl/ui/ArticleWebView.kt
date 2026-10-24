package app.sroka.feature.reader.impl.ui

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.net.Uri
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import app.sroka.feature.reader.impl.EffectiveTheme
import app.sroka.feature.reader.impl.ProgressReport
import app.sroka.feature.reader.impl.ReaderHtml
import app.sroka.feature.reader.impl.parseProgressMessage
import java.io.File

private class WebState {
    var loadedHtml: String? = null
    var theme: EffectiveTheme? = null
    var scale: Float = 0f
    var topSignal: Int = 0
    var header: String = ""
    var appliedHeader: String = ""
    var pageReady: Boolean = false
}

/**
 * Hardened WebView showing an already wrapped article document (DECISIONS A10). Files come from
 * [articlesDir] through WebViewAssetLoader; no file/content access, no network loads.
 *
 * [html] must be produced by `ReaderHtml.wrap`; [theme]/[textScale] changes after load are applied by script.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
internal fun ArticleWebView(
    html: String,
    baseUrl: String,
    articlesDir: File,
    theme: EffectiveTheme,
    textScale: Float,
    onProgress: (ProgressReport) -> Unit,
    onLinkClick: (String) -> Unit,
    onRendererGone: () -> Unit,
    /** Vertical scroll delta in px (positive = content moved up, i.e. the user scrolled down). */
    onScrollDelta: (Float) -> Unit = {},
    scrollToTopSignal: Int = 0,
    /** `ReaderHtml.headerScript(..)` for the current header, or empty; pushed without reloading the page. */
    headerScript: String = "",
    /** Overrides the WebView background (the detail card colour in two-pane mode). */
    backgroundArgb: Int = theme.backgroundArgb,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val currentOnProgress by rememberUpdatedState(onProgress)
    val currentOnLink by rememberUpdatedState(onLinkClick)
    val currentOnScrollDelta by rememberUpdatedState(onScrollDelta)
    val currentOnRendererGone by rememberUpdatedState(onRendererGone)
    val state = remember { WebState() }
    val webViewRef = remember { arrayOfNulls<WebView>(1) }
    val assetLoader = remember(articlesDir) {
        articlesDir.mkdirs()
        WebViewAssetLoader.Builder()
            .setDomain(ReaderHtml.ASSET_HOST)
            .addPathHandler("/articles/", WebViewAssetLoader.InternalStoragePathHandler(context, articlesDir))
            .build()
    }

    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_PAUSE -> webViewRef[0]?.onPause()
                Lifecycle.Event.ON_RESUME -> webViewRef[0]?.onResume()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            WebView(ctx).apply {
                webViewRef[0] = this
                setBackgroundColor(backgroundArgb)
                configure()
                setOnScrollChangeListener { _, _, scrollY, _, oldScrollY ->
                    currentOnScrollDelta((scrollY - oldScrollY).toFloat())
                }
                webViewClient = object : WebViewClient() {
                    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                        assetLoader.shouldInterceptRequest(request.url)

                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                        handleNavigation(view, request.url, baseUrl) { currentOnLink(it) }
                        return true // never navigate the WebView itself
                    }

                    // Returning true keeps the app alive when the renderer crashes or is killed. The
                    // caller drops this WebView from composition, whose onRelease destroys it.
                    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                        if (webViewRef[0] === view) webViewRef[0] = null
                        currentOnRendererGone()
                        return true
                    }

                    override fun onPageFinished(view: WebView, url: String?) {
                        // A header change that raced the page load is applied once the script exists.
                        state.pageReady = true
                        if (state.header.isNotEmpty() && state.header != state.appliedHeader) {
                            state.appliedHeader = state.header
                            view.evaluateJavascript(state.header, null)
                        }
                    }

                    override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) = Unit
                }
                installBridge { currentOnProgress(it) }
            }
        },
        update = { view ->
            state.header = headerScript
            if (state.loadedHtml != html) {
                state.loadedHtml = html
                state.appliedHeader = headerScript // the wrapped document carries the header it was built with
                state.pageReady = false
                state.theme = theme
                state.scale = textScale
                view.loadDataWithBaseURL(baseUrl, html, "text/html", "utf-8", null)
            } else if (state.theme != theme || state.scale != textScale) {
                state.theme = theme
                state.scale = textScale
                view.evaluateJavascript(ReaderHtml.appearanceScript(theme, textScale), null)
            }
            if (headerScript.isNotEmpty() && headerScript != state.appliedHeader && state.pageReady) {
                state.appliedHeader = headerScript
                view.evaluateJavascript(headerScript, null)
            }
            if (state.topSignal != scrollToTopSignal) {
                state.topSignal = scrollToTopSignal
                view.scrollTo(0, 0)
                view.evaluateJavascript("window.scrollTo(0,0);", null)
            }
            view.setBackgroundColor(backgroundArgb)
        },
        onRelease = { view ->
            webViewRef[0] = null
            view.stopLoading()
            view.destroy()
        },
    )
}

@SuppressLint("SetJavaScriptEnabled")
private fun WebView.configure() {
    settings.apply {
        javaScriptEnabled = true // only the app's nonce'd reader script runs (CSP)
        allowFileAccess = false
        allowContentAccess = false
        @Suppress("DEPRECATION")
        allowFileAccessFromFileURLs = false
        @Suppress("DEPRECATION")
        allowUniversalAccessFromFileURLs = false
        domStorageEnabled = false
        databaseEnabled = false
        setGeolocationEnabled(false)
        blockNetworkLoads = true
        mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        setSupportZoom(false)
        builtInZoomControls = false
        displayZoomControls = false
        textZoom = 100 // text size is the app's own --scale
        cacheMode = WebSettings.LOAD_NO_CACHE
        safeBrowsingEnabled = true
    }
    if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
        WebSettingsCompat.setAlgorithmicDarkeningAllowed(settings, false) // the reader themes itself
    }
    isVerticalScrollBarEnabled = true
}

private fun WebView.installBridge(onReport: (ProgressReport) -> Unit) {
    if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
        WebViewCompat.addWebMessageListener(
            this,
            ReaderHtml.BRIDGE_NAME,
            setOf(ReaderHtml.ASSET_ORIGIN),
        ) { _, message: WebMessageCompat, _: Uri, isMainFrame: Boolean, _ ->
            if (isMainFrame) parseProgressMessage(message.data)?.let(onReport)
        }
    } else {
        addJavascriptInterface(
            object {
                @JavascriptInterface
                fun post(message: String?) {
                    parseProgressMessage(message)?.let(onReport)
                }
            },
            ReaderHtml.FALLBACK_BRIDGE_NAME,
        )
    }
}

/** http(s) links leave the app; fragment links on the article scroll in place; everything else is dropped. */
private fun handleNavigation(view: WebView, uri: Uri, baseUrl: String, onExternal: (String) -> Unit) {
    val scheme = uri.scheme?.lowercase()
    if (uri.host == ReaderHtml.ASSET_HOST) {
        val fragment = uri.fragment
        if (fragment != null && uri.toString().substringBefore('#') == baseUrl) {
            val quoted = org.json.JSONObject.quote(fragment)
            view.evaluateJavascript("window.__srokaScrollToId&&window.__srokaScrollToId($quoted);", null)
        }
    } else if (scheme == "http" || scheme == "https") {
        onExternal(uri.toString())
    }
}
