import AppNavigation
import Dependencies
import SettingsFeature
import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI

/// The app's root. Picks one of four screens, in this order:
/// 1. the blocking "update needed" screen (`versionGate`),
/// 2. the shell for a signed-in (or expired) session,
/// 3. the sign-in flow for a signed-out session,
/// 4. a plain paper-coloured screen until the session is known.
///
/// **Seams for the live graph (stream L1).** All three have working defaults, so the app runs on the fakes today:
/// - `session`: the session root. `nil` follows `authRepository.session` itself; pass a value to drive it from the
///   live graph instead (changes are applied; signing out resets all navigation state).
/// - `versionGate`: `.open` by default; `.updateRequired(storeURL:)` replaces the whole app.
/// - `pendingDeepLinkItemId` with `onDeepLinkHandled`: an item id from `sroka://item/{id}` or a notification. The
///   shell opens it as soon as it is on screen (immediately when it already is) and then calls `onDeepLinkHandled`
///   so the owner can clear it.
struct RootView: View {
    var session: SessionState?
    var versionGate: VersionGate
    var pendingDeepLinkItemId: String?
    var onDeepLinkHandled: () -> Void

    @State private var router: AppRouter
    @State private var models: ShellModels
    @Dependency(\.authRepository) private var auth

    init(
        session: SessionState? = nil,
        versionGate: VersionGate = .open,
        pendingDeepLinkItemId: String? = nil,
        onDeepLinkHandled: @escaping () -> Void = {}
    ) {
        self.session = session
        self.versionGate = versionGate
        self.pendingDeepLinkItemId = pendingDeepLinkItemId
        self.onDeepLinkHandled = onDeepLinkHandled
        let router = AppRouter(session: session)
        _router = State(initialValue: router)
        _models = State(initialValue: ShellModels(router: router))
    }

    var body: some View {
        RootContent(router: router, models: models, versionGate: versionGate)
            .task(id: session) { await followSession() }
            .onChange(of: pendingDeepLinkItemId, initial: true) { _, itemId in
                guard let itemId else { return }
                router.open(itemId: itemId)
                onDeepLinkHandled()
            }
            .task { await DebugRoute.applyIfRequested(to: router, consent: models.consent) }
    }

    private func followSession() async {
        if let session {
            router.sessionChanged(session)
            return
        }
        for await state in auth.session {
            router.sessionChanged(state)
        }
    }
}

private struct RootContent: View {
    let router: AppRouter
    let models: ShellModels
    let versionGate: VersionGate

    var body: some View {
        switch versionGate {
        case .updateRequired(let storeURL):
            UpdateRequiredView(storeURL: storeURL)
        case .open:
            if router.showsShell {
                ShellView(router: router, models: models)
            } else if router.showsAuth {
                AuthRoot(intents: models.intents)
            } else {
                SrokaColor.background.ignoresSafeArea()
            }
        }
    }
}

/// The signed-in shell: compact tabs or regular split view (size class decides), plus everything presented over
/// either: Settings and the tag editor, the sign-in-again cover, the undo toast and the consent prompt.
private struct ShellView: View {
    @Bindable var router: AppRouter
    let models: ShellModels
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        layout
            .consentPrompt(models.consent)
            .overlay(alignment: .bottom) {
                UndoToastOverlay(router: router)
                    .padding(.bottom, sizeClass == .regular ? 16 : 76)
            }
            .animation(.snappy, value: router.toast?.id)
            .sheet(item: $router.sheet) { sheet in
                ShellSheetContent(sheet: sheet, router: router, intents: models.intents)
            }
            .fullScreenCover(isPresented: $router.isSignInAgainPresented) {
                AuthRoot(intents: models.intents)
            }
    }

    @ViewBuilder private var layout: some View {
        if sizeClass == .regular {
            RegularShell(router: router, models: models)
        } else {
            CompactShell(router: router, models: models)
        }
    }
}

#Preview {
    withDependencies {
        $0.useFakes(Fakes())
    } operation: {
        RootView()
    }
}
