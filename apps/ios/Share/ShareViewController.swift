import Dependencies
import Foundation
import ShareFeature
import SrokaCore
import SrokaDatabase
import SrokaDesign
import SrokaShareLive
import SrokaTesting
import SwiftUI
import TagsFeature
import UIKit

/// Share extension entry point (`NSExtensionPrincipalClass`). The system shows this controller's view over the
/// sharing app; it stays clear and presents the save sheet as a small page sheet on top, so the sharing app
/// remains visible behind it. Keep it light: no reader, Firebase or download code (extension memory limit).
final class ShareViewController: UIViewController, UISheetPresentationControllerDelegate {
    private var composition: ShareComposition?
    private var model: ShareViewModel?
    private var sheet: UIViewController?
    private var presented = false
    private var completed = false
    private var hostObservers: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        SrokaFont.registerFonts()
        // A previous run of this process may have left the shared database suspended.
        AppDatabase.resume()
        observeHostLifecycle()
        let composition = ShareComposition()
        self.composition = composition
        model = composition.makeModel { [weak self] intent in self?.handle(intent) }
    }

    /// While the host app is in the background the extension holds no SQLite lock (a lock held while suspended
    /// gets the process killed: 0xdead10cc).
    private func observeHostLifecycle() {
        let center = NotificationCenter.default
        hostObservers = [
            center.addObserver(forName: .NSExtensionHostDidEnterBackground, object: nil, queue: .main) { _ in
                AppDatabase.suspend()
            },
            center.addObserver(forName: .NSExtensionHostWillEnterForeground, object: nil, queue: .main) { _ in
                AppDatabase.resume()
            },
        ]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !presented, let model else { return }
        presented = true
        presentSheet(model: model)
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { @MainActor in
            let input = await ShareInputExtractor().extract(from: items)
            await model.start(input)
        }
    }

    // MARK: Sheet

    private func presentSheet(model: ShareViewModel) {
        let composition = composition
        let root = ShareSheetView(model: model) { context in
            composition?.tagEditor(context)
        }
        let host = UIHostingController(rootView: root)
        host.modalPresentationStyle = .pageSheet
        if let controller = host.sheetPresentationController {
            let small = UISheetPresentationController.Detent.custom(identifier: .init("share.small")) { _ in 340 }
            controller.detents = [small]
            controller.selectedDetentIdentifier = small.identifier
            controller.prefersGrabberVisible = true
            controller.prefersScrollingExpandsWhenScrolledToEdge = false
            controller.delegate = self
        }
        sheet = host
        present(host, animated: true)
    }

    /// The user swiped the sheet away.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let model else { return complete() }
        Task { await model.sheetDismissed() }
    }

    // MARK: Intents

    private func handle(_ intent: ShareIntent) {
        switch intent {
        case .dismiss:
            close()
        case .openURL(let url):
            openHostApp(url)
            close()
        }
    }

    private func close() {
        guard let sheet, sheet.presentingViewController != nil else { return complete() }
        sheet.dismiss(animated: true) { [weak self] in self?.complete() }
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        let graph = composition?.graph
        Task { @MainActor [weak self] in
            // A write still running (a tag save the editor left behind) commits before the database is suspended.
            await graph?.closeWrites()
            guard let self else { return }
            for observer in hostObservers { NotificationCenter.default.removeObserver(observer) }
            hostObservers = []
            AppDatabase.suspend()
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// A share extension cannot call `UIApplication.shared`; `extensionContext.open` only works for some
    /// extension kinds, so fall back to the responder chain. Needs a check on a real device.
    private func openHostApp(_ url: URL) {
        extensionContext?.open(url) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in self?.openThroughResponderChain(url) }
        }
    }

    private func openThroughResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }
}

// MARK: - Composition

/// The only place that decides which services the extension runs on: the live graph over the App Group database
/// the app created (`SrokaShareLive`). When it cannot open, the sheet shows "Open Sroka" or the error state and
/// touches no service, so fakes stand in.
@MainActor
private final class ShareComposition {
    let graph: ShareGraph?
    let startup: ShareStartup
    let environment: AppEnvironment?

    init() {
        let configuration = Bundle.main.infoDictionary.flatMap(ShareConfiguration.init(infoDictionary:))
        environment = configuration?.environment
        switch configuration.map(ShareGraph.open) {
        case .ready(let graph):
            self.graph = graph
            startup = .ready
        case .failed(let startup):
            graph = nil
            self.startup = startup
        case nil:
            graph = nil
            startup = .unavailable
        }
    }

    func install(into values: inout DependencyValues) {
        if let graph {
            graph.install(into: &values)
        } else {
            values.useFakes(.empty)
            if let environment { values.appEnvironment = environment }
        }
    }

    func makeModel(onIntent: @escaping @MainActor (ShareIntent) -> Void) -> ShareViewModel {
        let graph = graph
        return withDependencies {
            install(into: &$0)
        } operation: {
            ShareViewModel(startup: startup, pushOnce: { await graph?.pushOnce() }, onIntent: onIntent)
        }
    }

    /// The app's tag editor over the live graph. It writes the tags itself, then reports `finished`.
    func tagEditor(_ context: ShareTagEditorContext) -> some View {
        ShareTagEditor(
            model: withDependencies {
                install(into: &$0)
            } operation: {
                TagEditorViewModel(itemId: context.request.itemId) { await context.finished() }
            })
    }
}

/// Keeps one editor model for the sheet's lifetime.
private struct ShareTagEditor: View {
    @State private var model: TagEditorViewModel

    init(model: @autoclosure () -> TagEditorViewModel) {
        _model = State(wrappedValue: model())
    }

    var body: some View {
        TagEditorSheet(model: model)
    }
}
