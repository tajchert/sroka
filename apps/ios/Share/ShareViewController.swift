import ShareFeature
import SrokaDesign
import SwiftUI
import UIKit

/// Share extension entry point (`NSExtensionPrincipalClass`). Hosts the SwiftUI save sheet; the real
/// sheet and its save pipeline come from the ShareFeature stream.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        SrokaFont.registerFonts()
        let sheet = ShareSheetStub { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let host = UIHostingController(rootView: sheet)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

private struct ShareSheetStub: View {
    let done: () -> Void

    var body: some View {
        NavigationStack {
            SharePlaceholderView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: done)
                    }
                }
        }
    }
}
