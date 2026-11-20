import AuthFeature
import SrokaDesign
import SrokaLive
import SwiftUI

/// Picks the top-level screen from `AppModel.root`: update required, sign-in, or the library layout (`RootView`).
/// `AppModel` is in the environment for the root navigation (pending deep link: `appModel.deepLinks`).
struct AppRoot: View {
    let runtime: AppRuntime
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .environment(runtime.model)
            .onOpenURL { runtime.model.deepLinks.handle($0) }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active: runtime.sceneBecameActive()
                case .background: runtime.sceneEnteredBackground()
                default: break
                }
            }
            .task { runtime.start() }
    }

    @ViewBuilder private var content: some View {
        switch runtime.model.root {
        case .launching: Color.clear
        case .updateRequired: UpdateRequiredView()
        case .signedOut: SignedOutRoot()
        case .library: RootView()
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

/// Blocking screen while this build is below the server's minimum (`/v1/config` `minVersions.ios`).
struct UpdateRequiredView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Update Sroka", systemImage: "arrow.down.app")
        } description: {
            Text("This version of Sroka is no longer supported. Update it from the App Store to keep reading.")
        }
    }
}

#Preview("Update required") {
    UpdateRequiredView()
}
