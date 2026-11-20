import SrokaCore
import SrokaDesign
import SwiftUI

/// Empty states of the list: first-run onboarding, empty Archive and "Nothing matches".
struct LibraryEmptyView: View {
    let kind: LibraryEmptyState
    let extensionConnected: Bool
    let clipboardHasLink: Bool
    let actions: LibraryActions

    var body: some View {
        switch kind {
        case .onboarding:
            OnboardingView(
                extensionConnected: extensionConnected,
                clipboardHasLink: clipboardHasLink,
                actions: actions
            )
        case .archiveEmpty:
            EmptyMessage(
                systemImage: "archivebox",
                title: Text("Archive is empty", bundle: #bundle),
                message: Text("Articles you finish or archive show up here", bundle: #bundle)
            )
        case .noMatches:
            EmptyMessage(
                systemImage: "line.3.horizontal.decrease.circle",
                title: Text("Nothing matches", bundle: #bundle),
                message: nil,
                actionTitle: Text("Clear filters", bundle: #bundle),
                action: actions.clearFilters
            )
        }
    }
}

struct EmptyMessage: View {
    let systemImage: String
    let title: Text
    let message: Text?
    var actionTitle: Text?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
                .accessibilityHidden(true)
            title.font(.brandHeading(.title3)).foregroundStyle(SrokaColor.onSurface)
            if let message {
                message.font(.subheadline).foregroundStyle(SrokaColor.onSurfaceVariant).multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(action: action) { actionTitle.frame(minHeight: 44) }
                    .glassControl()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 56)
        .accessibilityElement(children: .contain)
    }
}

/// First run: "Start your list" with three steps.
struct OnboardingView: View {
    let extensionConnected: Bool
    let clipboardHasLink: Bool
    let actions: LibraryActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Start your list", bundle: #bundle)
                .font(.brandHeading(.title2))
                .foregroundStyle(SrokaColor.onSurface)
                .padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
            OnboardingStep(
                systemImage: "square.and.arrow.up",
                title: Text("Share any link to Sroka", bundle: #bundle),
                isDone: false,
                action: nil
            )
            OnboardingStep(
                systemImage: "puzzlepiece.extension",
                title: Text("Save from Chrome", bundle: #bundle),
                isDone: extensionConnected,
                action: actions.chromeStepTapped
            )
            OnboardingStep(
                systemImage: "link.badge.plus",
                title: Text("Paste a link", bundle: #bundle),
                isDone: false,
                emphasized: true,
                action: actions.pasteStepTapped
            )
            if clipboardHasLink {
                HStack {
                    Text("Save link from clipboard", bundle: #bundle)
                        .font(.subheadline)
                        .foregroundStyle(SrokaColor.onSurfaceVariant)
                    Spacer()
                    PasteLinkButton { actions.saveClipboard($0) }
                }
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .frame(maxWidth: SrokaMetrics.readableWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

struct OnboardingStep: View {
    let systemImage: String
    let title: Text
    let isDone: Bool
    var emphasized = false
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: isDone ? "checkmark" : systemImage)
                .font(.body.weight(isDone ? .bold : .regular))
                .foregroundStyle(isDone ? SrokaColor.onPrimary : SrokaColor.onSurfaceVariant)
                .frame(width: 38, height: 38)
                .background(isDone ? SrokaColor.primary : SrokaColor.surfaceContainer, in: .circle)
                .accessibilityHidden(true)
            title
                .font(.callout.weight(emphasized ? .medium : .regular))
                .foregroundStyle(emphasized ? SrokaColor.primary : SrokaColor.onSurface)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isDone ? .isSelected : [])
    }
}
