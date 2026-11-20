import Foundation
import SrokaCore
import SrokaDesign

/// Article header rendered at the top of the document.
struct ReaderHeader: Sendable, Equatable {
    var site: String
    var title: String
    /// Pre-formatted "N min read · " prefix (may be empty); the live percentage follows it.
    var metaPrefix: String
    var progress: Double
    /// Text of the partial-save warning row, or nil when the save is complete.
    var partialWarning: String?
}

/// A reading position reported by the reader script.
struct ProgressReport: Sendable, Equatable {
    var progress: Double
    var anchor: Int?
    var atEnd: Bool = false
}

/// Parses the reader script's `"0.5321|12|1"` message (anchor may be empty; the optional third field is `1`
/// when the page is scrolled to its very end); nil when malformed.
func parseProgressMessage(_ message: Any?) -> ProgressReport? {
    guard let message = message as? String else { return nil }
    let parts = message.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 || parts.count == 3 else { return nil }
    guard let progress = Double(parts[0]), progress.isFinite else { return nil }
    var anchor: Int?
    if !parts[1].isEmpty {
        guard let value = Int(parts[1]) else { return nil }
        anchor = value >= 0 ? value : nil
    }
    var atEnd = false
    if parts.count == 3 {
        switch parts[2] {
        case "0": atEnd = false
        case "1": atEnd = true
        default: return nil
        }
    }
    return ProgressReport(progress: min(max(progress, 0), 1), anchor: anchor, atEnd: atEnd)
}

/// Wraps the sanitized `article.html` for the on-device web view: CSP meta, theme CSS and the reader
/// script. Pure Swift so it is unit-testable. The page itself runs no JavaScript (the web view disables it);
/// the script is injected as a `WKUserScript` in a separate content world, see ``ReaderHtml/script(startAnchor:startProgress:)``.
enum ReaderHtml {
    /// Name of the progress message handler (registered only in the reader content world).
    static let messageHandlerName = "srokaReader"
    /// The original 6rem of space under the article.
    static let defaultEndPaddingPx = 96
    /// Space under the article reserved for the end-of-article card.
    static let endCardPaddingPx = 300

    static let contentSecurityPolicy =
        "default-src 'none'; img-src \(ArticleScheme.name): data:; style-src 'unsafe-inline'"

    static func wrap(
        articleHtml: String,
        baseURL: String,
        theme: EffectiveTheme,
        textScale: Double,
        font: ReaderFont = .sans,
        lineSpacing: ReaderLineSpacing = .normal,
        header: ReaderHeader? = nil,
        endPaddingPx: Int = defaultEndPaddingPx
    ) -> String {
        let headerHtml = header.map(Self.headerHtml) ?? ""
        let inject =
            "<meta http-equiv=\"Content-Security-Policy\" content=\"\(escapeAttr(contentSecurityPolicy))\">"
            + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            + "<base href=\"\(escapeAttr(baseURL))\">"
            + "<style>\(css)</style>"
        let htmlAttrs =
            " data-theme=\"\(theme.cssName)\" data-font=\"\(font.cssName)\" "
            + "style=\"--scale:\(scaleText(textScale));--lh:\(lineHeightText(lineSpacing));"
            + "--end:\(min(max(endPaddingPx, 0), 1000))px\""
        if articleHtml.firstMatch(of: headOpen) != nil {
            // Keep a full document; inject ours first and set theme attributes on <html>.
            var result = replaceFirst(in: articleHtml, regex: headOpen) { $0 + inject }
            if !headerHtml.isEmpty {
                result = replaceFirst(in: result, regex: bodyOpen) { $0 + headerHtml }
            }
            if result.firstMatch(of: htmlOpen) != nil {
                result = replaceFirst(in: result, regex: htmlOpen) { _ in "<html\(htmlAttrs)>" }
            }
            return result
        }
        if articleHtml.firstMatch(of: htmlOpen) != nil {
            return replaceFirst(in: articleHtml, regex: htmlOpen) { _ in
                "<html\(htmlAttrs)><head><meta charset=\"utf-8\">\(inject)</head>"
            }
        }
        return "<!doctype html><html\(htmlAttrs)><head><meta charset=\"utf-8\">\(inject)</head>"
            + "<body>\(headerHtml)\(articleHtml)</body></html>"
    }

    /// JS to run after load when theme, text size, font or line spacing changes; keeps the reading position.
    static func appearanceScript(
        theme: EffectiveTheme,
        textScale: Double,
        font: ReaderFont = .sans,
        lineSpacing: ReaderLineSpacing = .normal
    ) -> String {
        "window.__srokaSetAppearance&&window.__srokaSetAppearance("
            + "'\(theme.cssName)',\(scaleText(textScale)),'\(font.cssName)',\(lineHeightText(lineSpacing)));"
    }

    /// JS that updates the header in place (no document reload). The values travel as one JSON document
    /// inside a JS string literal and are written with `textContent` on the page side.
    static func headerScript(_ header: ReaderHeader) -> String {
        let warn = header.partialWarning.map(jsonString) ?? "null"
        let json =
            "{\"site\":\(jsonString(header.site)),\"title\":\(jsonString(header.title)),"
            + "\"metaPrefix\":\(jsonString(header.metaPrefix)),\"warn\":\(warn)}"
        return "window.__srokaSetHeader&&window.__srokaSetHeader(\(jsonString(json)));"
    }

    /// Scrolls to the element with `id` (in-page `#fragment` links; navigation itself is cancelled).
    static func scrollToIdScript(_ id: String) -> String {
        "window.__srokaScrollToId&&window.__srokaScrollToId(\(jsonString(id)));"
    }

    /// A quoted string valid as both a JSON and a JS literal, safe to embed in script or HTML.
    static func jsonString(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _
            where scalar.value < 0x20 || scalar == "<" || scalar == ">" || scalar == "&"
                || scalar.value == 0x2028 || scalar.value == 0x2029:
                result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    static func headerHtml(_ header: ReaderHeader) -> String {
        let percent = Int((min(max(header.progress, 0), 1) * 100).rounded())
        let warn =
            header.partialWarning.map {
                "<div class=\"sk-warn\">\(warnSvg)<span>\(escapeText($0))</span></div>"
            } ?? ""
        return "<header class=\"sk-head\"><div class=\"sk-site\">\(escapeText(header.site))</div>"
            + "<div class=\"sk-title\">\(escapeText(header.title))</div>"
            + "<div class=\"sk-meta\">\(escapeText(header.metaPrefix))<span id=\"sk-pct\">\(percent)%</span></div>"
            + "\(warn)</header>"
    }

    /// The reader script with the start position filled in. Runs in the reader content world only.
    static func script(startAnchor: Int?, startProgress: Double) -> String {
        scriptTemplate
            .replacingOccurrences(of: "__SEL__", with: "\"\(Limits.progressAnchorSelector)\"")
            .replacingOccurrences(of: "__START_A__", with: startAnchor.map(String.init) ?? "null")
            .replacingOccurrences(of: "__START_P__", with: String(format: "%.4f", min(max(startProgress, 0), 1)))
            .replacingOccurrences(of: "__HANDLER__", with: messageHandlerName)
    }

    // MARK: Private

    // Computed: `Regex` is not `Sendable`, so it cannot be a stored static under Swift 6.
    private static var headOpen: Regex<(Substring, Substring?)> { #/<head(\s[^>]*)?>/#.ignoresCase() }
    private static var htmlOpen: Regex<(Substring, Substring?)> { #/<html(\s[^>]*)?>/#.ignoresCase() }
    private static var bodyOpen: Regex<(Substring, Substring?)> { #/<body(\s[^>]*)?>/#.ignoresCase() }

    private static func replaceFirst(
        in source: String,
        regex: Regex<(Substring, Substring?)>,
        transform: (String) -> String
    ) -> String {
        guard let match = source.firstMatch(of: regex) else { return source }
        var result = source
        result.replaceSubrange(match.range, with: transform(String(match.output.0)))
        return result
    }

    private static let warnSvg =
        "<svg viewBox=\"0 0 24 24\" width=\"18\" height=\"18\" fill=\"currentColor\" aria-hidden=\"true\">"
        + "<path d=\"M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z\"/></svg>"

    private static func escapeText(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttr(_ string: String) -> String {
        escapeText(string).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func scaleText(_ scale: Double) -> String { String(format: "%.2f", scale) }

    private static func lineHeightText(_ spacing: ReaderLineSpacing) -> String {
        String(format: "%.2f", spacing.lineHeight)
    }

    private static let scriptTemplate = #"""
        (function(){
        var SEL=__SEL__,START_A=__START_A__,START_P=__START_P__;
        var timer=null,last=0,user=false,lastEnd=false,root=document.documentElement;
        function sc(){return document.scrollingElement||root}
        function anchors(){return document.body?document.body.querySelectorAll(SEL):[]}
        function send(m){try{window.webkit.messageHandlers.__HANDLER__.postMessage(m)}catch(e){}}
        function firstVisible(){var l=anchors();for(var i=0;i<l.length;i++){if(l[i].getBoundingClientRect().bottom>1)return i}return null}
        function report(){var s=sc(),max=s.scrollHeight-s.clientHeight,p=max>0?Math.min(1,Math.max(0,s.scrollTop/max)):0,a=firstVisible(),e=atEnd();lastEnd=e;var pe=document.getElementById("sk-pct");if(pe)pe.textContent=Math.round(p*100)+"%";send(p.toFixed(4)+"|"+(a==null?"":a)+"|"+(e?1:0))}
        function atEnd(){var s=sc();return s.scrollTop+s.clientHeight>=s.scrollHeight-4}
        function fits(){var s=sc();return s.scrollHeight-s.clientHeight<=2}
        function toAnchor(i){var el=anchors()[i];if(el){var s=sc();s.scrollTop=el.getBoundingClientRect().top+s.scrollTop-8;return true}return false}
        function restore(){if(user)return;if(START_A!==null&&toAnchor(START_A))return;if(START_P>0){var s=sc(),max=s.scrollHeight-s.clientHeight;if(max>0)s.scrollTop=START_P*max}}
        addEventListener("scroll",function(){var n=Date.now();clearTimeout(timer);if(n-last>=150){last=n;report()}else{timer=setTimeout(function(){last=Date.now();report()},150)}},{passive:true});
        ["touchstart","wheel","keydown","mousedown"].forEach(function(e){addEventListener(e,function(){user=true},{passive:true})});
        if(window.ResizeObserver){new ResizeObserver(function(){if(atEnd()!==lastEnd&&document.readyState==="complete")report()}).observe(root)}
        function start(){restore();if(fits())report();setTimeout(function(){restore();if(fits())report()},300)}
        if(document.readyState==="complete"){start()}else{addEventListener("load",start)}
        window.__srokaSetAppearance=function(theme,scale,font,lh){var a=firstVisible();root.setAttribute("data-theme",theme);root.setAttribute("data-font",font);root.style.setProperty("--scale",scale);root.style.setProperty("--lh",lh);if(a!==null)toAnchor(a)};
        window.__srokaSetHeader=function(raw){var h;try{h=JSON.parse(raw)}catch(e){return}var head=document.querySelector(".sk-head");var old=document.getElementById("sk-pct");var pct=old?old.textContent:"0%";if(!head){head=document.createElement("header");head.className="sk-head";document.body.insertBefore(head,document.body.firstChild)}
        while(head.firstChild)head.removeChild(head.firstChild);
        function div(c,t){var d=document.createElement("div");d.className=c;if(t!==undefined)d.textContent=t;head.appendChild(d);return d}
        div("sk-site",h.site);div("sk-title",h.title);var m=div("sk-meta",h.metaPrefix);var sp=document.createElement("span");sp.id="sk-pct";sp.textContent=pct;m.appendChild(sp);
        if(h.warn){var w=div("sk-warn");var ns="http://www.w3.org/2000/svg",sv=document.createElementNS(ns,"svg");sv.setAttribute("viewBox","0 0 24 24");sv.setAttribute("width","18");sv.setAttribute("height","18");sv.setAttribute("fill","currentColor");sv.setAttribute("aria-hidden","true");var pa=document.createElementNS(ns,"path");pa.setAttribute("d","M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z");sv.appendChild(pa);var t=document.createElement("span");t.textContent=h.warn;w.appendChild(sv);w.appendChild(t)}};
        window.__srokaScrollToId=function(id){var el=document.getElementById(id);if(el)el.scrollIntoView()};
        window.__srokaScrollToFraction=function(f){user=true;var s=sc(),max=s.scrollHeight-s.clientHeight;if(max>0)s.scrollTop=Math.min(1,Math.max(0,f))*max;clearTimeout(timer);report()};
        })();
        """#

    /// X / Twitter and Reddit post cards (repo decisions D11, D13; same classes and look as the web reader's
    /// `POST_CARD_CSS`): one card per post, a thread line joining the avatars of consecutive cards, quoted posts as
    /// nested cards. Copied unchanged from the Android reader.
    static let postCardCss = #"""
        .sr-thread{display:flex;flex-direction:column;gap:1rem;margin:0 0 1.1em}
        .sr-post{position:relative;padding:.9rem 1rem;border:1px solid var(--rule);border-radius:14px;background:var(--bg);background:color-mix(in srgb,var(--fg) 2.5%,var(--bg))}
        .sr-thread>.sr-post+.sr-post::before{content:"";position:absolute;left:calc(1rem + 19px);top:calc(-1rem - 1px);height:1rem;width:2px;background:var(--rule)}
        .sr-post-focus{border-color:var(--link)}
        .sr-post-head{display:flex;align-items:center;flex-wrap:wrap;column-gap:.35em;margin:0 0 .6rem;font-size:.8em;line-height:1.3;color:var(--muted)}
        .sr-post-head .sr-avatar{width:40px;height:40px;border-radius:50%;object-fit:cover;margin-right:.35em;flex:none}
        .sr-post-who strong{color:var(--fg)}
        .sr-post-head a{color:inherit;text-decoration:none}
        .sr-post-body>:last-child{margin-bottom:0}
        .sr-post-body figure img{display:block;width:100%;border-radius:10px;border:1px solid var(--rule)}
        .sr-post-body figure>a{display:block}
        .sr-post-stats{margin:.6rem 0 0;color:var(--muted);font-size:.85em}
        blockquote.sr-post-quote{margin:0 0 1.1em;padding:.7rem .85rem;border:1px solid var(--rule);border-radius:10px;background:var(--bg);color:var(--fg);font-size:.92em}
        blockquote.sr-post-quote .sr-avatar{width:22px;height:22px}
        blockquote.sr-note{padding:.6rem .85rem;border:1px solid var(--rule);border-radius:10px;color:var(--fg);font-size:.9em}
        .sr-comments{display:flex;flex-direction:column;gap:.75rem;margin:0 0 1.1em}
        .sr-replies{margin:.7rem 0 0;padding:0 0 0 .85rem;border-left:2px solid var(--rule)}
        .sr-reply{padding:.55rem 0 0}.sr-reply:first-child{padding-top:0}
        .sr-reply.sr-post-focus{margin:0 0 0 -.85rem;padding:.55rem .85rem;border-left:2px solid var(--link);background:var(--bg);background:color-mix(in srgb,var(--link) 6%,var(--bg))}
        .sr-reply>.sr-post-head{margin-bottom:.35rem}.sr-reply>.sr-post-stats{margin-top:.35rem}
        .sr-thread-foot{color:var(--muted);text-align:center}
        """#
        .replacingOccurrences(of: "\n", with: "")

    /// Palette variables per theme: background, text and link come from `ReaderPalette` (the single source for
    /// native chrome and page); muted, rule and warning tones are the reader-only extras.
    private static func themeVariables() -> String {
        func block(_ selector: String, _ palette: ReaderPalette, _ extras: String) -> String {
            "\(selector){--bg:\(palette.backgroundHex.lowercased());--fg:\(palette.textHex.lowercased());"
                + "--link:\(palette.linkHex.lowercased());\(extras)}"
        }
        return ":root{--scale:1;--lh:1.65;--end:96px;--warn:#7a5a00;--muted:#5d5f66;--rule:#e3e3df;"
            + "--bg:\(ReaderPalette.light.backgroundHex.lowercased());--fg:\(ReaderPalette.light.textHex.lowercased());"
            + "--link:\(ReaderPalette.light.linkHex.lowercased())}"
            + block("html[data-theme=dark]", .dark, "--muted:#a5a8ae;--rule:#2a2d2f;--warn:#e8cf86")
            + block("html[data-theme=sepia]", .sepia, "--muted:#8a7656;--rule:#e0d3b8")
    }

    /// The reader stylesheet (theme variables, typography, post cards).
    static var css: String { themeVariables() + baseCss + postCardCss }

    private static let baseCss = #"""
        .sk-head{margin:0 0 1.4em}.sk-site{font-size:14px;font-weight:500;color:var(--link);margin-bottom:14px}.sk-title{font-size:28px;font-weight:600;line-height:1.2;margin-bottom:14px}.sk-meta{font-size:14px;color:var(--muted)}.sk-warn{display:flex;align-items:center;gap:8px;font-size:14px;color:var(--warn);margin-top:14px}
        .sk-head~article>h1:first-child{display:none}.sk-head~article>h1:first-child+.byline{font-size:14px;color:var(--muted);margin-top:0}
        html{background:var(--bg);-webkit-text-size-adjust:100%}
        body{margin:0 auto;max-width:min(42em,720px);padding:1.25rem 1.1rem var(--end);background:var(--bg);color:var(--fg);font-family:system-ui,sans-serif;font-size:calc(18px*var(--scale));line-height:var(--lh);overflow-wrap:break-word}
        html[data-font=serif] body{font-family:ui-serif,'New York',Georgia,serif}
        h1,h2,h3,h4,h5,h6{line-height:1.25;margin:1.6em 0 .6em}h1{font-size:1.6em}h2{font-size:1.35em}h3{font-size:1.15em}
        p,ul,ol,pre,blockquote,figure,table{margin:0 0 1.1em}
        a{color:var(--link)}
        img,video,svg{max-width:100%;height:auto}
        figure{margin-inline:0}figcaption{font-size:.8em;color:var(--muted);margin-top:.4em}
        blockquote{margin-inline:0;padding-inline-start:1em;border-inline-start:3px solid var(--link);color:var(--muted)}
        pre,code{font-family:ui-monospace,Menlo,monospace;font-size:.86em}
        pre{overflow-x:auto;padding:.8em 1em;border:1px solid var(--rule);border-radius:6px;white-space:pre}
        hr{border:0;border-top:1px solid var(--rule);margin:2em 0}
        table{border-collapse:collapse;display:block;overflow-x:auto}td,th{border:1px solid var(--rule);padding:.35em .6em}
        html[data-theme=dark] img{filter:brightness(.85) contrast(1.05)}
        """#
        .replacingOccurrences(of: "\n", with: "")
}
