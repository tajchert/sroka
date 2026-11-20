import SafariServices
import SrokaCore
import SrokaDesign
import SwiftUI

/// 3 pt reading-progress line at the top edge: brand blue on light and sepia pages, yellow on dark.
struct ReaderProgressLine: View {
    let progress: Double
    let theme: EffectiveTheme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(SrokaColor.progressTrack.opacity(0.35))
                Rectangle()
                    .fill(theme.isDark ? SrokaColor.brandYellow : SrokaColor.brand)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel(Text("Reading progress", bundle: #bundle))
        .accessibilityValue(Text("\(Int((progress * 100).rounded())) percent", bundle: #bundle))
    }
}

extension View {
    /// Glass for the reader's floating chrome (bottom bar, toast, end-of-article card): regular Liquid Glass tinted
    /// with the page colour, so article text scrolling behind it stays out of the labels. The system swaps it for a
    /// solid fill under Reduce Transparency. Neighbours go in one `GlassEffectContainer` (`ReaderBottomOverlay`).
    func readerGlass<S: Shape>(_ theme: EffectiveTheme, in shape: S) -> some View {
        glassEffect(.regular.tint(theme.palette.background.opacity(0.85)), in: shape)
    }
}

/// Floating glass bar: favorite, archive, tags, share.
struct ReaderBottomBar<ShareContent: View>: View {
    let theme: EffectiveTheme
    let isFavorite: Bool
    let isArchived: Bool
    let onFavorite: () -> Void
    let onArchive: () -> Void
    let onTags: () -> Void
    @ViewBuilder let share: () -> ShareContent

    var body: some View {
        HStack(spacing: 4) {
            barButton(
                isFavorite ? "star.fill" : "star",
                label: isFavorite
                    ? Text("Remove from favorites", bundle: #bundle) : Text("Add to favorites", bundle: #bundle),
                tint: isFavorite ? SrokaColor.brandYellow : nil, action: onFavorite)
            barButton(
                isArchived ? "tray.and.arrow.up" : "archivebox",
                label: isArchived ? Text("Move to My List", bundle: #bundle) : Text("Archive", bundle: #bundle),
                action: onArchive)
            barButton("tag", label: Text("Edit tags", bundle: #bundle), action: onTags)
            share()
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 52, height: 44)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(theme.palette.text)
        .readerGlass(theme, in: .capsule)
    }

    private func barButton(_ symbol: String, label: Text, tint: Color? = nil, action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint ?? theme.palette.text)
                .frame(width: 52, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Transient notice above the bottom bar ("Article refreshed", "Resumed at 42%" + Start over).
struct ReaderToastView: View {
    let theme: EffectiveTheme
    let toast: ReaderToast
    let onStartOver: () -> Void

    var body: some View {
        ReaderToastContent(theme: theme, toast: toast, onStartOver: onStartOver)
            .readerGlass(theme, in: .capsule)
    }
}

/// The toast's text and button without the glass, which renders blank off-screen (snapshot tests).
struct ReaderToastContent: View {
    let theme: EffectiveTheme
    let toast: ReaderToast
    let onStartOver: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            message
            if case .resumed = toast {
                Button(action: onStartOver) {
                    Text("Start over", bundle: #bundle).fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SrokaColor.brand)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .foregroundStyle(theme.palette.text)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var message: some View {
        switch toast {
        case .refreshed: Text("Article refreshed", bundle: #bundle)
        case .refreshedPartial: Text("Refreshed, still a partial copy", bundle: #bundle)
        case .refreshFailed: Text("Couldn’t refresh the article", bundle: #bundle)
        case .resumed(let percent): Text("Resumed at \(percent)%", bundle: #bundle)
        }
    }
}

/// In-app browser for links inside an article.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// An `http(s)` link the user tapped, presented in `SafariView`.
struct SafariDestination: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
}
