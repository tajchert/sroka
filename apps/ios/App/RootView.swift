import AppNavigation
import Dependencies
import SettingsFeature
import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI

/// The library root under `AppRoot` (which already handles the update gate and the signed-out screen). Follows
/// `authRepository.session` into the router, so the shell stays up for an expired session (with its sign-in-again
/// cover) and resets for another account. Shows, in this order:
/// 1. the shell for a signed-in (or expired) session,
/// 2. the sign-in flow for a signed-out session (only for the moment before `AppRoot` switches screens),
/// 3. a plain paper-coloured screen until the session is known.
///
/// `pendingDeepLinkItemId` with `onDeepLinkHandled`: an item id from `sroka://item/{id}` or a notification. The
/// shell opens it as soon as it is on screen (immediately when it already is) and then calls `onDeepLinkHandled` so
/// the owner can clear it.
struct RootView: View {
    var pendingDeepLinkItemId: String?
    var onDeepLinkHandled: () -> Void

    @State private var router: AppRouter
    @State private var models: ShellModels
    @Dependency(\.authRepository) private var auth

    init(pendingDeepLinkItemId: String? = nil, onDeepLinkHandled: @escaping () -> Void = {}) {
        self.pendingDeepLinkItemId = pendingDeepLinkItemId
        self.onDeepLinkHandled = onDeepLinkHandled
        let router = AppRouter()
        _router = State(initialValue: router)
        _models = State(initialValue: ShellModels(router: router))
    }

    var body: some View {
        RootContent(router: router, models: models)
            .task { await followSession() }
            .onChange(of: pendingDeepLinkItemId, initial: true) { _, itemId in
                guard let itemId else { return }
                router.open(itemId: itemId)
                onDeepLinkHandled()
            }
            .task { await DebugRoute.applyIfRequested(to: router, consent: models.consent) }
    }

    private func followSession() async {
        for await state in auth.session {
            router.sessionChanged(state)
        }
    }
}

private struct RootContent: View {
    let router: AppRouter
    let models: ShellModels

    var body: some View {
        if router.showsShell {
            ShellView(router: router, models: models)
        } else if router.showsAuth {
            AuthRoot(intents: models.intents)
        } else {
            SrokaColor.background.ignoresSafeArea()
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
