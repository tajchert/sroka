import AppNavigation
import Dependencies
import SrokaCore
import SrokaDesign
import SwiftUI

/// The root's own glass toast: "Archived · Undo" after the reader archived an item and left. Lists show their
/// own toasts for actions taken on them; this one covers actions taken in the reader, whose screen is gone.
struct UndoToastOverlay: View {
    let router: AppRouter
    @Dependency(\.libraryRepository) private var library
    @Dependency(\.continuousClock) private var clock

    var body: some View {
        if let toast = router.toast {
            GlassToast(
                Text("Archived"),
                actionTitle: Text("Undo"),
                action: { undo(toast) }
            )
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: toast.id) {
                AccessibilityNotification.Announcement(String(localized: "Archived")).post()
                try? await clock.sleep(for: .seconds(4))
                router.dismissToast(id: toast.id)
            }
        }
    }

    private func undo(_ toast: RouterToast) {
        switch toast.kind {
        case .archived(let itemId):
            router.dismissToast(id: toast.id)
            Task { await library.setStatus(id: itemId, status: .unread) }
        }
    }
}
