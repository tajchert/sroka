package app.sroka.feature.reader.impl

import app.sroka.core.domain.ContentStore
import app.sroka.core.model.ReaderTheme
import java.security.SecureRandom
import java.util.Base64

/** Palette actually applied to the article; [ReaderTheme.AUTO] resolves to LIGHT or DARK. */
enum class EffectiveTheme(val cssName: String, val backgroundArgb: Int, val isDark: Boolean) {
    LIGHT("light", 0xFFFBFBF9.toInt(), false),
    SEPIA("sepia", 0xFFF3EAD8.toInt(), false),
    DARK("dark", 0xFF121314.toInt(), true),
}

/** Resolves the stored reader theme against the current app brightness. */
fun resolveTheme(theme: ReaderTheme, systemDark: Boolean): EffectiveTheme = when (theme) {
    ReaderTheme.AUTO -> if (systemDark) EffectiveTheme.DARK else EffectiveTheme.LIGHT
    ReaderTheme.LIGHT -> EffectiveTheme.LIGHT
    ReaderTheme.SEPIA -> EffectiveTheme.SEPIA
    ReaderTheme.DARK -> EffectiveTheme.DARK
}

/** A reading position reported by the reader script. */
data class ProgressReport(val progress: Float, val anchor: Int?)

/** Parses the reader script's `"0.5321|12"` (anchor may be empty) message; null when malformed. */
fun parseProgressMessage(message: String?): ProgressReport? {
    if (message == null) return null
    val parts = message.split('|')
    if (parts.size != 2) return null
    val progress = parts[0].toFloatOrNull()?.takeIf { it.isFinite() } ?: return null
    val anchor = if (parts[1].isEmpty()) null else parts[1].toIntOrNull() ?: return null
    return ProgressReport(progress.coerceIn(0f, 1f), anchor?.takeIf { it >= 0 })
}

/**
 * Wraps the sanitized `article.html` for the on-device WebView (DECISIONS A10): CSP meta, theme CSS,
 * and the one nonce'd reader script. Pure Kotlin so it is unit-testable.
 */
object ReaderHtml {
    const val BRIDGE_NAME = "SrokaBridge"
    const val FALLBACK_BRIDGE_NAME = "SrokaBridgeJs"
    const val ASSET_HOST = "appassets.androidplatform.net"
    const val ASSET_ORIGIN = "https://$ASSET_HOST"
    const val ANCHOR_SELECTOR = "p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,figure"

    fun newNonce(): String {
        val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes).filter { it.isLetterOrDigit() }
    }

    fun csp(nonce: String): String =
        "default-src 'none'; img-src $ASSET_ORIGIN data:; style-src 'unsafe-inline'; script-src 'nonce-$nonce'"

    fun wrap(
        articleHtml: String,
        baseUrl: String = ContentStore.ARTICLE_ASSET_BASE_URL,
        theme: EffectiveTheme,
        textScale: Float,
        startAnchor: Int?,
        startProgress: Float,
        nonce: String = newNonce(),
    ): String {
        val inject = "<meta http-equiv=\"Content-Security-Policy\" content=\"${escapeAttr(csp(nonce))}\">" +
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" +
            "<base href=\"${escapeAttr(baseUrl)}\">" +
            "<style>$CSS</style>" +
            "<script nonce=\"$nonce\">${script(startAnchor, startProgress)}</script>"
        val htmlAttrs = " data-theme=\"${theme.cssName}\" style=\"--scale:${scaleText(textScale)}\""
        val headOpen = Regex("<head(\\s[^>]*)?>", RegexOption.IGNORE_CASE)
        val htmlOpen = Regex("<html(\\s[^>]*)?>", RegexOption.IGNORE_CASE)
        return when {
            headOpen.containsMatchIn(articleHtml) -> {
                // Keep a full document; inject ours first and set theme attributes on <html>.
                val withHead = replaceMatch(articleHtml, headOpen) { it + inject }
                if (htmlOpen.containsMatchIn(withHead)) {
                    replaceMatch(withHead, htmlOpen) { "<html$htmlAttrs>" }
                } else {
                    withHead
                }
            }
            htmlOpen.containsMatchIn(articleHtml) ->
                replaceMatch(articleHtml, htmlOpen) { "<html$htmlAttrs><head><meta charset=\"utf-8\">$inject</head>" }
            else ->
                "<!doctype html><html$htmlAttrs><head><meta charset=\"utf-8\">$inject</head><body>$articleHtml</body></html>"
        }
    }

    /** JS to run after load when theme or text size changes; keeps the reading position. */
    fun appearanceScript(theme: EffectiveTheme, textScale: Float): String =
        "window.__srokaSetAppearance&&window.__srokaSetAppearance('${theme.cssName}',${scaleText(textScale)});"

    private inline fun replaceMatch(src: String, regex: Regex, transform: (String) -> String): String {
        val m = regex.find(src) ?: return src
        return src.replaceRange(m.range, transform(m.value))
    }

    private fun scaleText(scale: Float): String = String.format(java.util.Locale.ROOT, "%.2f", scale)

    private fun escapeAttr(s: String) =
        s.replace("&", "&amp;").replace("\"", "&quot;").replace("<", "&lt;").replace(">", "&gt;")

    private fun script(startAnchor: Int?, startProgress: Float): String = SCRIPT
        .replace("__SEL__", "\"$ANCHOR_SELECTOR\"")
        .replace("__START_A__", startAnchor?.toString() ?: "null")
        .replace("__START_P__", String.format(java.util.Locale.ROOT, "%.4f", startProgress.coerceIn(0f, 1f)))
        .replace("__BRIDGE__", BRIDGE_NAME)
        .replace("__FALLBACK__", FALLBACK_BRIDGE_NAME)

    private val SCRIPT = """
(function(){
var SEL=__SEL__,START_A=__START_A__,START_P=__START_P__;
var timer=null,user=false,root=document.documentElement;
function sc(){return document.scrollingElement||root}
function anchors(){return document.body?document.body.querySelectorAll(SEL):[]}
function send(m){try{if(window.__BRIDGE__&&window.__BRIDGE__.postMessage){window.__BRIDGE__.postMessage(m)}else if(window.__FALLBACK__){window.__FALLBACK__.post(m)}}catch(e){}}
function firstVisible(){var l=anchors();for(var i=0;i<l.length;i++){if(l[i].getBoundingClientRect().bottom>1)return i}return null}
function report(){var s=sc(),max=s.scrollHeight-s.clientHeight,p=max>0?Math.min(1,Math.max(0,s.scrollTop/max)):0,a=firstVisible();send(p.toFixed(4)+"|"+(a==null?"":a))}
function toAnchor(i){var el=anchors()[i];if(el){var s=sc();s.scrollTop=el.getBoundingClientRect().top+s.scrollTop-8;return true}return false}
function restore(){if(user)return;if(START_A!==null&&toAnchor(START_A))return;if(START_P>0){var s=sc(),max=s.scrollHeight-s.clientHeight;if(max>0)s.scrollTop=START_P*max}}
addEventListener("scroll",function(){clearTimeout(timer);timer=setTimeout(report,500)},{passive:true});
["touchstart","wheel","keydown","mousedown"].forEach(function(e){addEventListener(e,function(){user=true},{passive:true})});
addEventListener("load",function(){restore();setTimeout(restore,300)});
window.__srokaSetAppearance=function(theme,scale){var a=firstVisible();root.setAttribute("data-theme",theme);root.style.setProperty("--scale",scale);if(a!==null)toAnchor(a)};
window.__srokaScrollToId=function(id){var el=document.getElementById(id);if(el)el.scrollIntoView()};
})();
""".trimIndent()

    private val CSS = """
:root{--scale:1;--bg:#fbfbf9;--fg:#1b1c1d;--muted:#6b6e71;--link:#0b7f7c;--rule:#e3e3df}
html[data-theme=dark]{--bg:#121314;--fg:#dcdcd8;--muted:#8f9396;--link:#4cd6c8;--rule:#2a2d2f}
html[data-theme=sepia]{--bg:#f3ead8;--fg:#40321f;--muted:#8a7656;--link:#1f6f6a;--rule:#e0d3b8}
html{background:var(--bg);-webkit-text-size-adjust:100%}
body{margin:0 auto;max-width:42em;padding:1.25rem 1.1rem 6rem;background:var(--bg);color:var(--fg);font-family:system-ui,Roboto,sans-serif;font-size:calc(18px*var(--scale));line-height:1.65;overflow-wrap:break-word}
h1,h2,h3,h4,h5,h6{line-height:1.25;margin:1.6em 0 .6em}h1{font-size:1.6em}h2{font-size:1.35em}h3{font-size:1.15em}
p,ul,ol,pre,blockquote,figure,table{margin:0 0 1.1em}
a{color:var(--link)}
img,video,svg{max-width:100%;height:auto}
figure{margin-inline:0}figcaption{font-size:.8em;color:var(--muted);margin-top:.4em}
blockquote{margin-inline:0;padding-inline-start:1em;border-inline-start:3px solid var(--link);color:var(--muted)}
pre,code{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.86em}
pre{overflow-x:auto;padding:.8em 1em;border:1px solid var(--rule);border-radius:6px;white-space:pre}
hr{border:0;border-top:1px solid var(--rule);margin:2em 0}
table{border-collapse:collapse;display:block;overflow-x:auto}td,th{border:1px solid var(--rule);padding:.35em .6em}
html[data-theme=dark] img{filter:brightness(.85) contrast(1.05)}
""".trimIndent().replace("\n", "")
}
