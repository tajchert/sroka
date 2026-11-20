import SrokaCore
import SrokaDesign
import SwiftUI

/// The reader screen for one item (article or PDF). Navigation (tags, next item, leaving) goes out through
/// `onIntent`; the app root owns those screens.
public struct ReaderView: View {
    @State private var model: ReaderViewModel
    @State private var isChromeVisible = true
    @State private var safari: SafariDestination?
    @State private var sheetHeight: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    public init(itemId: String, onIntent: @escaping (ReaderIntent) -> Void) {
        _model = State(initialValue: ReaderViewModel(itemId: itemId, onIntent: onIntent))
    }

    /// For previews and tests, which build the model against fakes.
    public init(model: ReaderViewModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        ReaderScreen(model: model, isChromeVisible: $isChromeVisible, safari: $safari, sheetHeight: $sheetHeight)
            .task { await model.observe() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.readerLeft() }
            }
            .onDisappear {
                model.readerLeft()
                model.stop()
                UIApplication.shared.isIdleTimerDisabled = false
            }
    }
}

/// The screen body; separate from `ReaderView` so snapshot tests can render it with a given model.
struct ReaderScreen: View {
    @Bindable var model: ReaderViewModel
    @Binding var isChromeVisible: Bool
    @Binding var safari: SafariDestination?
    @Binding var sheetHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var theme: EffectiveTheme {
        EffectiveTheme.resolve(model.appearance.preferences.readerTheme, systemDark: colorScheme == .dark)
    }

    private var originalURL: URL? { model.item.flatMap { URL(string: $0.url) } }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            if model.appearance.isLoaded {
                ReaderContent(
                    model: model, theme: theme, originalURL: originalURL, isChromeVisible: $isChromeVisible,
                    onOpenLink: { safari = SafariDestination(url: $0) })
            }
        }
        .overlay(alignment: .top) {
            if model.isReaderShown {
                ReaderProgressLine(progress: model.progress, theme: theme).ignoresSafeArea(edges: .top)
            }
        }
        .safeAreaBar(edge: .bottom) {
            ReaderBottomOverlay(model: model, theme: theme, isChromeVisible: isChromeVisible)
        }
        .animation(.snappy, value: isChromeVisible)
        .animation(.snappy, value: model.toast)
        .toolbar(isChromeVisible ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(theme.isDark ? .dark : .light, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ReaderToolbar(model: model, originalURL: originalURL)
        }
        .confirmationDialog(
            Text("Delete this article?", bundle: #bundle), isPresented: $model.isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await model.deleteConfirmed() }
            } label: {
                Text("Delete", bundle: #bundle)
            }
        } message: {
            Text("It is removed from your library and from this device.", bundle: #bundle)
        }
        .sheet(isPresented: $model.isAppearancePresented) {
            AppearanceSheet(model: model.appearance).fittedSheetDetent($sheetHeight)
        }
        .sheet(item: $safari) { destination in
            SafariView(url: destination.url).ignoresSafeArea()
        }
        .onChange(of: model.keepAwake, initial: true) { _, keepAwake in
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        .onChange(of: model.state, initial: true) { _, state in
            // The item was deleted elsewhere (or the id is invalid): nothing left to show.
            if case .missing = state { model.closeTapped() }
            isChromeVisible = true
        }
    }
}

/// The article, PDF or status view for the current state.
private struct ReaderContent: View {
    let model: ReaderViewModel
    let theme: EffectiveTheme
    let originalURL: URL?
    @Binding var isChromeVisible: Bool
    let onOpenLink: (URL) -> Void

    var body: some View {
        switch model.state {
        case .loading, .missing:
            Color.clear
        case .ready(let document):
            ArticleWebView(
                document: document,
                restore: model.restorePoint(),
                appearance: webAppearance,
                header: header,
                endPaddingPx: model.endsWithCard ? ReaderHtml.endCardPaddingPx : ReaderHtml.defaultEndPaddingPx,
                scrollToTopRequest: model.scrollToTopRequest,
                onProgress: { model.readingPositionReported($0) },
                onScrollDirection: { isChromeVisible = $0 == .up },
                onTap: {
                    isChromeVisible.toggle()
                    model.touchActivity()
                },
                onOpenLink: onOpenLink,
                onProcessTerminated: { model.webProcessTerminated() },
                onLoaded: { model.articleDisplayed() }
            )
            .ignoresSafeArea()
        case .pdfReady(let file):
            PdfReaderView(
                file: file, initialPage: model.restorePoint().anchor ?? 0, theme: theme,
                onPage: { page, count in model.pdfPageChanged(page: page, pageCount: count) })
        case .downloading:
            ReaderDownloadingView(isPdf: model.isPdf, theme: theme)
        case .notDownloaded(let reason):
            ReaderNotDownloadedView(
                reason: reason, isPdf: model.isPdf, originalURL: originalURL, theme: theme,
                onRetry: { model.retryTapped() })
        case .parsePending:
            ReaderParsePendingView(originalURL: originalURL, theme: theme)
        case .parseFailed(let error):
            ReaderParseFailedView(
                error: error, originalURL: originalURL, theme: theme,
                onTryAgain: { Task { await model.refreshTapped() } })
        case .rendererGone:
            ReaderRendererGoneView(originalURL: originalURL, theme: theme, onReload: { model.reloadTapped() })
        }
    }

    private var webAppearance: WebAppearance {
        let preferences = model.appearance.preferences
        return WebAppearance(
            theme: theme, textScale: preferences.readerTextScale, font: preferences.readerFont,
            lineSpacing: preferences.readerLineSpacing)
    }

    private var header: ReaderHeader? {
        guard let item = model.item else { return nil }
        let site = item.siteName.flatMap { $0.isEmpty ? nil : $0 } ?? displayDomain(item.url)
        let prefix = item.readingMinutes.map { String(localized: "\($0) min read · ", bundle: #bundle) } ?? ""
        let warning: String? =
            if !model.settledPartial {
                nil
            } else if item.parseError?.trimmingCharacters(in: .whitespaces).lowercased() == "paywalled" {
                String(localized: "Preview only", bundle: #bundle)
            } else {
                String(localized: "Partial copy", bundle: #bundle)
            }
        return ReaderHeader(
            site: site, title: item.displayTitle, metaPrefix: prefix, progress: 0, partialWarning: warning)
    }
}

/// Toast, end-of-article card and the floating bar.
private struct ReaderBottomOverlay: View {
    let model: ReaderViewModel
    let theme: EffectiveTheme
    let isChromeVisible: Bool

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            chrome
        }
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            if hasChrome { ReaderChromeScrim(theme: theme) }
        }
    }

    /// Something floats above the page (toast, end card or the bar), so the page needs the scrim.
    private var hasChrome: Bool {
        model.toast != nil || model.isEndCardShown || (isChromeVisible && model.isReaderShown && model.item != nil)
    }

    private var chrome: some View {
        VStack(spacing: 10) {
            if let toast = model.toast {
                ReaderToastView(theme: theme, toast: toast, onStartOver: { model.startOverTapped() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.isEndCardShown {
                EndOfArticleCard(
                    minutes: model.item?.readingMinutes,
                    isArchived: model.item?.status == .archived,
                    next: model.endNext,
                    theme: theme,
                    onArchive: { Task { await model.archiveAndNextTapped() } },
                    onKeep: { model.keepTapped() },
                    onOpenNext: { model.upNextTapped() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if isChromeVisible, model.isReaderShown, let item = model.item {
                ReaderBottomBar(
                    theme: theme,
                    isFavorite: item.isFavorite,
                    isArchived: item.status == .archived,
                    onFavorite: { Task { await model.favoriteTapped() } },
                    onArchive: { Task { await model.archiveTapped() } },
                    onTags: { model.tagsTapped() }
                ) {
                    ReaderShareButton(model: model)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// Share link for an article, the file for a PDF.
private struct ReaderShareButton: View {
    let model: ReaderViewModel

    var body: some View {
        if case .pdfReady(let file) = model.state {
            ShareLink(item: file) {
                Label {
                    Text("Share PDF", bundle: #bundle)
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        } else if let url = model.item.flatMap({ URL(string: $0.url) }) {
            ShareLink(item: url) {
                Label {
                    Text("Share link", bundle: #bundle)
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }
}

/// Appearance button (articles only) and the overflow menu.
private struct ReaderToolbar: ToolbarContent {
    let model: ReaderViewModel
    let originalURL: URL?

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if case .ready = model.state {
                Button {
                    model.appearanceTapped()
                } label: {
                    Text("Aa", bundle: #bundle).fontWeight(.semibold)
                }
                .accessibilityLabel(Text("Appearance", bundle: #bundle))
            }
            Menu {
                if !model.isPdf, let originalURL {
                    Link(destination: originalURL) {
                        Label {
                            Text("Open original", bundle: #bundle)
                        } icon: {
                            Image(systemName: "safari")
                        }
                    }
                }
                if !model.isPdf {
                    Button {
                        Task { await model.refreshTapped() }
                    } label: {
                        Label {
                            Text("Refresh article", bundle: #bundle)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(model.isOffline || model.isRefreshing)
                }
                Button(role: .destructive) {
                    model.deleteTapped()
                } label: {
                    Label {
                        Text("Delete", bundle: #bundle)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel(Text("More options", bundle: #bundle))
        }
    }
}

extension ReaderViewModel {
    /// The article or PDF itself is on screen (the progress line and bottom bar belong to it).
    var isReaderShown: Bool {
        switch state {
        case .ready, .pdfReady: true
        default: false
        }
    }

    /// Whether the end-of-article card is up, which also decides the page's bottom padding.
    var isEndCardShown: Bool {
        guard case .ready = state else { return false }
        return endsWithCard && atEnd && !isEndCardKept
    }

    /// A completely saved article ends with the card; partial copies end plainly.
    var endsWithCard: Bool {
        item?.parseStatus == .ok && !settledPartial
    }
}
