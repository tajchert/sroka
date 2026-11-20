import PDFKit
import SrokaCore
import SrokaDesign
import SwiftUI

/// Native PDF viewer: continuous vertical scrolling, "Page N of M", and the page index as the reading anchor.
struct PdfReaderView: View {
    let file: URL
    /// 0-based page to open at (the saved anchor).
    let initialPage: Int
    let theme: EffectiveTheme
    let onPage: (_ page: Int, _ pageCount: Int) -> Void

    @State private var position: PdfPosition?
    @State private var isUnreadable = false

    var body: some View {
        ZStack(alignment: .top) {
            if isUnreadable {
                PdfUnreadableView(file: file, theme: theme)
            } else {
                PdfKitView(
                    file: file, initialPage: initialPage, theme: theme,
                    onUnreadable: { isUnreadable = true },
                    onPage: { page, count in
                        position = PdfPosition(page: page, count: count)
                        onPage(page, count)
                    }
                )
                .ignoresSafeArea()
                if let position {
                    Text("Page \(position.page + 1) of \(position.count)", bundle: #bundle)
                        .font(.footnote.monospacedDigit())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .floatingGlass()
                        .padding(.top, 8)
                        .accessibilityLabel(Text("Page \(position.page + 1) of \(position.count)", bundle: #bundle))
                }
            }
        }
    }
}

private struct PdfPosition: Equatable {
    var page: Int
    var count: Int
}

/// "Can't display this PDF".
struct PdfUnreadableView: View {
    let file: URL
    let theme: EffectiveTheme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Can’t display this PDF", bundle: #bundle).font(.headline)
            Text("The file may be damaged or protected. Try opening it in another app.", bundle: #bundle)
                .font(.callout)
                .multilineTextAlignment(.center)
                .opacity(0.75)
            ShareLink(item: file) {
                Text("Open with another app", bundle: #bundle)
            }
            .buttonStyle(.borderedProminent)
            .tint(SrokaColor.brand)
        }
        .foregroundStyle(theme.palette.text)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PdfKitView: UIViewRepresentable {
    let file: URL
    let initialPage: Int
    let theme: EffectiveTheme
    let onUnreadable: () -> Void
    let onPage: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageBreakMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.backgroundColor = UIColor(theme.palette.background)
        guard let document = PDFDocument(url: file), !document.isLocked, document.pageCount > 0 else {
            DispatchQueue.main.async(execute: onUnreadable)
            return view
        }
        view.document = document
        context.coordinator.observe(view, onPage: onPage)
        if let page = document.page(at: min(max(initialPage, 0), document.pageCount - 1)) {
            view.go(to: page)
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.backgroundColor = UIColor(theme.palette.background)
        context.coordinator.onPage = onPage
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPage: (Int, Int) -> Void = { _, _ in }
        private var token: (any NSObjectProtocol)?

        func observe(_ view: PDFView, onPage: @escaping (Int, Int) -> Void) {
            self.onPage = onPage
            token = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, let document = view.document, let page = view.currentPage else { return }
                    self.onPage(document.index(for: page), document.pageCount)
                }
            }
            // The first page is reported once the view has laid out.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let document = view.document, let page = view.currentPage else { return }
                self.onPage(document.index(for: page), document.pageCount)
            }
        }

        func stopObserving() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }
}
