import AuthFeature
import SrokaDesign
import SrokaLive
import SwiftUI

/// Picks the top-level screen from `AppModel.root`: update required, sign-in, or the library layout (`RootView`).
/// `AppModel` is in the environment for the root navigation (pending deep link: `appModel.deepLinks`).
struct AppRoot: View {
    let runtime: AppRuntime

    var body: some View {
        content
            .environment(runtime.model)
            .onOpenURL { runtime.model.deepLinks.handle($0) }
            .task { runtime.start() }
    }

    @ViewBuilder private var content: some View {
        switch runtime.model.root {
        case .launching: Color.clear
        case .updateRequired: UpdateRequiredView(storeURL: nil)
        case .signedOut: SignedOutRoot()
        case .library:
            RootView(
                pendingDeepLinkItemId: runtime.model.deepLinks.pendingItemId,
                onDeepLinkHandled: { _ = runtime.model.deepLinks.consumePendingItem() }
            )
        }
    }
}

/// The sign-in screen. On success the session stream moves the root to the library.
private struct SignedOutRoot: View {
    @State private var model = AuthViewModel()

    var body: some View {
        AuthView(model: model)
    }
}
