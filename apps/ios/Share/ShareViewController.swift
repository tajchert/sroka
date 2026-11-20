import Dependencies
import Foundation
import ShareFeature
import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI
import UIKit

/// Share extension entry point (`NSExtensionPrincipalClass`). The system shows this controller's view over the
/// sharing app; it stays clear and presents the save sheet as a small page sheet on top, so the sharing app
/// remains visible behind it. Keep it light: no reader, Firebase or download code (extension memory limit).
final class ShareViewController: UIViewController, UISheetPresentationControllerDelegate {
    private var model: ShareViewModel?
    private var sheet: UIViewController?
    private var presented = false
    private var completed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        SrokaFont.registerFonts()
        model = ShareComposition.makeModel { [weak self] intent in self?.handle(intent) }
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
        let root = ShareSheetView(model: model) { context in
            ShareComposition.tagEditor(context)
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
        extensionContext?.completeRequest(returningItems: nil)
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

/// The only place that decides which services the extension runs on. TODO(live graph): replace the fakes with
/// the live graph once the sync engine merges. It must provide `libraryRepository`, `tagRepository`,
/// `authRepository`, `pdfUploader` and `appEnvironment` (live value reads the extension's Info.plist), the
/// `ShareStartup` result of opening the shared database, and a bounded `pushOnce` (one `sync/push` with a
/// short timeout that never throws).
@MainActor
private enum ShareComposition {
    static func makeModel(onIntent: @escaping @MainActor (ShareIntent) -> Void) -> ShareViewModel {
        let fakes = Fakes(items: [], session: .signedIn(email: Fixtures.email))
        return withDependencies {
            $0.useFakes(fakes)
        } operation: {
            ShareViewModel(startup: .ready, pushOnce: {}, onIntent: onIntent)
        }
    }

    /// Placeholder tag editor: comma separated names. The app's tag editor replaces it with the live graph.
    static func tagEditor(_ context: ShareTagEditorContext) -> some View {
        PlaceholderTagEditor(context: context)
    }
}

private struct PlaceholderTagEditor: View {
    let context: ShareTagEditorContext
    @State private var text: String

    init(context: ShareTagEditorContext) {
        self.context = context
        _text = State(initialValue: context.request.initialTags.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Tags, separated by commas", text: $text)
                    .textInputAutocapitalization(.never)
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: context.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let names = text.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        Task { await context.save(names) }
                    }
                }
            }
        }
    }
}
