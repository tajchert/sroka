import SrokaCore
import SwiftUI

/// One library row: thumbnail (with reading-progress bar and status badge), title, "site · time"
/// line and a decorative favorite star. Stateless; the list adds swipe actions and taps. Reads as
/// one accessibility element; actions are the caller's custom actions.
public struct ItemRow: View {
    private let item: ItemSummary
    private let presentation: ItemRowPresentation
    private let onRetry: (() -> Void)?

    /// - Parameter onRetry: shown as a retry button in place of the star when the text failed.
    public init(_ item: ItemSummary, onRetry: (() -> Void)? = nil) {
        self.item = item
        presentation = ItemRowPresentation(item)
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(spacing: 12) {
            ItemThumbnail(item: item, presentation: presentation)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.rowTitle)
                    .foregroundStyle(
                        presentation.readState == .read ? SrokaColor.onSurfaceVariant : SrokaColor.onSurface
                    )
                    .lineLimit(2)
                Text(presentation.metaText)
                    .font(.rowMeta)
                    .foregroundStyle(metaColor)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel(title: item.displayTitle))
        .accessibilityAddTraits(.isButton)
    }

    private var metaColor: Color {
        switch presentation.status {
        case .failed: SrokaColor.error
        case .previewOnly, .partialCopy: SrokaColor.warning
        default: SrokaColor.onSurfaceVariant
        }
    }

    @ViewBuilder private var trailing: some View {
        if presentation.showsRetry, let onRetry {
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Try again", bundle: #bundle))
        } else if item.isFavorite {
            Image(systemName: "star.fill")
                .font(.footnote)
                .foregroundStyle(SrokaColor.brandYellow)
                .accessibilityHidden(true)
        }
    }
}

/// 48 pt thumbnail. Falls back to the site's first letter, a PDF tile or a spinner while preparing.
struct ItemThumbnail: View {
    let item: ItemSummary
    let presentation: ItemRowPresentation

    private static let size: CGFloat = 48
    private static let radius: CGFloat = 9

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(SrokaColor.surfaceHigh)
            content
            if presentation.showsProgressBar {
                ReadingProgressBar(progress: presentation.progress)
                    .frame(height: 3)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let status = presentation.status, status != .preparing {
                StatusBadge(status: status).offset(x: 6, y: -6)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        if presentation.status == .preparing {
            ProgressView().controlSize(.small)
        } else if let url = item.thumbnailPath {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                placeholder
            }
            .frame(width: Self.size, height: Self.size)
        } else {
            placeholder
        }
    }

    @ViewBuilder private var placeholder: some View {
        if presentation.isPDF {
            Image(systemName: "doc.richtext")
                .font(.title3)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
        } else {
            Text(String(item.domain.first.map { String($0).uppercased() } ?? "·"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(SrokaColor.primary)
        }
    }
}

/// 18 pt status badge: a paper disc with the status symbol.
struct StatusBadge: View {
    let status: ItemRowPresentation.Status

    var body: some View {
        Image(systemName: status.symbolName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
            .background(SrokaColor.background, in: .circle)
            .overlay(Circle().strokeBorder(SrokaColor.outlineVariant, lineWidth: 0.5))
    }

    private var tint: Color {
        switch status {
        case .failed: SrokaColor.error
        case .previewOnly, .partialCopy: SrokaColor.warning
        default: SrokaColor.onSurfaceVariant
        }
    }
}

/// Reading progress: beak yellow on a dark track. Used on thumbnails and continue-reading cards.
public struct ReadingProgressBar: View {
    private let progress: Double

    public init(progress: Double) {
        self.progress = min(max(progress, 0), 1)
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(SrokaColor.progressTrack)
                Rectangle().fill(SrokaColor.progress).frame(width: proxy.size.width * progress)
            }
        }
        .accessibilityHidden(true)
    }
}
