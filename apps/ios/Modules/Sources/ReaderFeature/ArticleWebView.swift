import OSLog
import SrokaCore
import SwiftUI
import WebKit

/// Everything the page's look depends on, applied live (no reload) through the reader script.
struct WebAppearance: Equatable {
    var theme: EffectiveTheme
    var textScale: Double
    var font: ReaderFont
    var lineSpacing: ReaderLineSpacing
}

/// Which way the user is scrolling; drives hiding the toolbars.
enum ScrollDirection: Sendable, Equatable {
    case down
    case up
}

/// Turns raw scroll offsets into direction changes with a small dead zone, so jitter does not flicker the bars.
struct ScrollDirectionTracker {
    var threshold: CGFloat = 14
    private var anchor: CGFloat?
    private var lastDirection: ScrollDirection?

    /// Feeds the new content offset (points from the top of the content); returns a direction only when it changes.
    mutating func update(offset: CGFloat, topOffset: CGFloat) -> ScrollDirection? {
        guard let reference = anchor else {
            anchor = offset
            return nil
        }
        // At the very top the bars are always shown.
        if offset <= topOffset + 1 {
            anchor = offset
            return emit(.up)
        }
        let delta = offset - reference
        if delta > threshold {
            anchor = offset
            return emit(.down)
        }
        if delta < -threshold {
            anchor = offset
            return emit(.up)
        }
        return nil
    }

    private mutating func emit(_ direction: ScrollDirection) -> ScrollDirection? {
        guard direction != lastDirection else { return nil }
        lastDirection = direction
        return direction
    }
}

/// The locked-down web view that shows one article. Security posture (all four hold at once):
/// - a content rule list blocks every http/https load, so nothing leaves the device;
/// - page JavaScript is off (`allowsContentJavaScript = false`); the only script is the reader script, injected
///   as a `WKUserScript` into its own content world, where the progress message handler lives;
/// - the page only reads `sroka-article://{itemId}/…`, served from that item's package by `ArticleSchemeHandler`;
/// - every navigation after the first load is cancelled; http(s) links open in `SFSafariViewController`.
struct ArticleWebView: UIViewRepresentable {
    let document: ReaderDocument
    let restore: RestorePoint
    let appearance: WebAppearance
    let header: ReaderHeader?
    let endPaddingPx: Int
    let scrollToTopRequest: Int
    let onProgress: (ProgressReport) -> Void
    let onScrollDirection: (ScrollDirection) -> Void
    let onTap: () -> Void
    let onOpenLink: (URL) -> Void
    let onProcessTerminated: () -> Void

    func makeCoordinator() -> ArticleWebViewCoordinator {
        ArticleWebViewCoordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView(document: document)
        context.coordinator.update(from: self, webView: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(from: self, webView: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: ArticleWebViewCoordinator) {
        coordinator.tearDown(webView)
    }
}

/// Name of the reader content world. Page scripts (disabled anyway) live in the page world and cannot reach it.
enum ReaderWorld {
    static let name = "sroka-reader"
    @MainActor static var world: WKContentWorld { .world(name: name) }
}

/// Blocks every http/https subresource and navigation.
enum ReaderLockdown {
    static let ruleListIdentifier = "app.sroka.reader.block-web"
    static let ruleListJSON = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#

    /// Compiled once per process; WebKit also caches it on disk by identifier.
    @MainActor private static var compiled: Task<WKContentRuleList?, Never>?

    @MainActor static func ruleList() async -> WKContentRuleList? {
        if let compiled { return await compiled.value }
        let task = Task { () -> WKContentRuleList? in
            do {
                return try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: ruleListIdentifier, encodedContentRuleList: ruleListJSON)
            } catch {
                Logger(subsystem: "app.sroka", category: "reader").error("content rule list failed to compile")
                return nil
            }
        }
        compiled = task
        return await task.value
    }
}

@MainActor
final class ArticleWebViewCoordinator: NSObject, WKNavigationDelegate, UIGestureRecognizerDelegate {
    private var parent: ArticleWebView?
    private var loadedDocument: ReaderDocument?
    private var appliedAppearance: WebAppearance?
    private var appliedHeader: ReaderHeader?
    private var appliedScrollToTop = 0
    private var allowInitialNavigation = false
    private var scrollObservation: NSKeyValueObservation?
    private var tracker = ScrollDirectionTracker()
    private var loadTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "app.sroka", category: "reader")

    // MARK: Construction

    func makeWebView(document: ReaderDocument) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = false
        configuration.setURLSchemeHandler(
            ArticleSchemeHandler(itemId: document.itemId, articlesDirectory: document.articlesDirectory),
            forURLScheme: ArticleScheme.name)
        configuration.userContentController.add(
            ProgressMessageHandler { [weak self] message in self?.progressMessageReceived(message) },
            contentWorld: ReaderWorld.world, name: ReaderHtml.messageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isInspectable = false
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        webView.addGestureRecognizer(tap)

        scrollObservation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.scrolled(scrollView) }
        }
        return webView
    }

    func tearDown(_ webView: WKWebView) {
        loadTask?.cancel()
        scrollObservation?.invalidate()
        scrollObservation = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    // MARK: Updates

    func update(from view: ArticleWebView, webView: WKWebView) {
        parent = view
        applyBackground(view.appearance.theme, to: webView)
        if loadedDocument != view.document {
            load(view, into: webView)
            return
        }
        if appliedAppearance != view.appearance {
            appliedAppearance = view.appearance
            let a = view.appearance
            run(
                ReaderHtml.appearanceScript(
                    theme: a.theme, textScale: a.textScale, font: a.font, lineSpacing: a.lineSpacing), in: webView)
        }
        if let header = view.header, header != appliedHeader {
            appliedHeader = header
            run(ReaderHtml.headerScript(header), in: webView)
        }
        if view.scrollToTopRequest != appliedScrollToTop {
            appliedScrollToTop = view.scrollToTopRequest
            webView.scrollView.setContentOffset(
                CGPoint(x: 0, y: -webView.scrollView.adjustedContentInset.top), animated: true)
        }
    }

    private func applyBackground(_ theme: EffectiveTheme, to webView: WKWebView) {
        let color = UIColor(theme.palette.background)
        webView.underPageBackgroundColor = color
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
        webView.overrideUserInterfaceStyle = theme.isDark ? .dark : .light
    }

    private func load(_ view: ArticleWebView, into webView: WKWebView) {
        loadedDocument = view.document
        appliedAppearance = view.appearance
        appliedHeader = view.header
        appliedScrollToTop = view.scrollToTopRequest
        tracker = ScrollDirectionTracker()
        guard let baseURL = ArticleScheme.baseURL(itemId: view.document.itemId) else {
            view.onProcessTerminated()
            return
        }
        let a = view.appearance
        let html = ReaderHtml.wrap(
            articleHtml: view.document.html, baseURL: baseURL.absoluteString, theme: a.theme, textScale: a.textScale,
            font: a.font, lineSpacing: a.lineSpacing, header: view.header, endPaddingPx: view.endPaddingPx)
        let script = ReaderHtml.script(startAnchor: view.restore.anchor, startProgress: view.restore.progress)
        loadTask?.cancel()
        loadTask = Task { [weak self, weak webView] in
            // The rule list must be installed before anything loads: without it the page could reach the network.
            guard let ruleList = await ReaderLockdown.ruleList(), !Task.isCancelled, let webView, let self else {
                self?.parent?.onProcessTerminated()
                return
            }
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            controller.add(ruleList)
            controller.removeAllUserScripts()
            controller.addUserScript(
                WKUserScript(
                    source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                    in: ReaderWorld.world))
            self.allowInitialNavigation = true
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    private func run(_ script: String, in webView: WKWebView) {
        webView.evaluateJavaScript(script, in: nil, in: ReaderWorld.world) { _ in }
    }

    // MARK: Events

    private func progressMessageReceived(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let report = parseProgressMessage(message.body) else { return }
        parent?.onProgress(report)
    }

    private func scrolled(_ scrollView: UIScrollView) {
        guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
        if let direction = tracker.update(
            offset: scrollView.contentOffset.y, topOffset: -scrollView.adjustedContentInset.top)
        {
            parent?.onScrollDirection(direction)
        }
    }

    @objc private func tapped() {
        parent?.onTap()
    }

    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.allowsContentJavaScript = false
        return (decide(navigationAction, in: webView), preferences)
    }

    /// Only the initial main-frame load of the article document is allowed; everything else is cancelled.
    /// A tapped http(s) link opens in the in-app browser, an in-page `#fragment` scrolls the reader, any other
    /// scheme (mailto:, tel:, javascript:, …) is ignored.
    private func decide(_ action: WKNavigationAction, in webView: WKWebView) -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame == true else { return .cancel }
        if allowInitialNavigation, action.navigationType == .other {
            allowInitialNavigation = false
            return .allow
        }
        guard action.navigationType == .linkActivated, let url = action.request.url else { return .cancel }
        switch url.scheme?.lowercased() {
        case "http", "https":
            parent?.onOpenLink(url)
        case ArticleScheme.name:
            if let fragment = url.fragment, !fragment.isEmpty, url.host?.lowercased() == webView.url?.host?.lowercased()
            {
                run(ReaderHtml.scrollToIdScript(fragment), in: webView)
            }
        default:
            logger.debug("ignored link with unsupported scheme")
        }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        parent?.onProcessTerminated()
    }
}

/// Forwards script messages without letting the user content controller retain the coordinator.
private final class ProgressMessageHandler: NSObject, WKScriptMessageHandler {
    private let handler: @MainActor (WKScriptMessage) -> Void

    init(handler: @escaping @MainActor (WKScriptMessage) -> Void) {
        self.handler = handler
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { handler(message) }
    }
}
