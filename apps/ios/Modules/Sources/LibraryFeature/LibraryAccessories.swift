import SrokaCore
import SrokaDesign
import SwiftUI

/// Favorites, Under 10 min and the top tags as a horizontal chip row.
struct FilterChipRow: View {
    let state: LibraryListState
    let actions: LibraryActions

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    Text("Favorites", bundle: #bundle),
                    systemImage: state.filters.favoritesOnly ? "star.fill" : "star",
                    isSelected: state.filters.favoritesOnly,
                    action: actions.favoritesFilter
                )
                FilterChip(
                    Text("Under 10 min", bundle: #bundle),
                    systemImage: "clock",
                    isSelected: state.filters.underTenMinutes,
                    action: actions.underTenFilter
                )
                ForEach(state.tagChips, id: \.self) { tag in
                    FilterChip(Text(verbatim: "#\(tag)"), isSelected: state.filters.tag == tag) {
                        actions.tagChip(tag)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(minHeight: 44)
    }
}

/// "Continue reading": up to ten partly read articles as small cards.
struct ContinueReadingStrip: View {
    let items: [ItemSummary]
    let onOpen: (ItemSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Continue reading", bundle: #bundle)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SrokaColor.onSurfaceVariant)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        ContinueReadingCard(item: item) { onOpen(item) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

struct ContinueReadingCard: View {
    let item: ItemSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SrokaColor.onSurface)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                if let minutes = item.readingMinutes {
                    Text(
                        "\(ItemRowPresentation.minutesLeft(minutes, progress: item.progress)) min left", bundle: #bundle
                    )
                    .font(.caption)
                    .foregroundStyle(SrokaColor.onSurfaceVariant)
                }
                ReadingProgressBar(progress: item.progress)
                    .frame(height: 3)
                    .clipShape(.capsule)
            }
            .padding(10)
            .frame(width: 164, alignment: .leading)
            .background(SrokaColor.surfaceContainer, in: .rect(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(item.displayTitle), \(Int((item.progress * 100).rounded()))%"))
    }
}

/// The sync card: sign in, catching up, offline or downloading.
struct SyncStatusCard: View {
    let kind: StatusCardKind
    let onSignIn: () -> Void

    var body: some View {
        card.padding(.horizontal, 16)
    }

    @ViewBuilder private var card: some View {
        switch kind {
        case .signInAgain:
            PaperBanner(
                systemImage: "person.crop.circle.badge.exclamationmark",
                title: Text("Sign in again to sync", bundle: #bundle),
                style: .warning,
                actionTitle: Text("Sign in", bundle: #bundle),
                action: onSignIn
            )
        case .resyncing(let fraction):
            PaperBanner(
                systemImage: "arrow.triangle.2.circlepath",
                title: fraction.map { Text("Catching up · \(Int(($0 * 100).rounded()))%", bundle: #bundle) }
                    ?? Text("Catching up", bundle: #bundle),
                message: Text(
                    "It’s been a while, so Sroka is re-syncing your whole library. You can keep reading, and nothing you change will be lost.",
                    bundle: #bundle
                ),
                progress: fraction
            )
        case .offline(let pending):
            PaperBanner(
                systemImage: "icloud.slash",
                title: pending > 0
                    ? Text("Offline. \(pending) changes will sync later.", bundle: #bundle)
                    : Text("Offline. Showing saved articles.", bundle: #bundle)
            )
        case .downloading(let done, let total):
            PaperBanner(
                systemImage: "arrow.down.circle",
                title: Text("Downloading for offline", bundle: #bundle),
                message: Text("\(done) of \(total)", bundle: #bundle),
                progress: Double(done) / Double(total)
            )
        }
    }
}

/// PDF upload progress or failure above the list.
struct UploadCard: View {
    let kind: UploadCardKind
    let onDismiss: () -> Void

    var body: some View {
        card.padding(.horizontal, 16)
    }

    @ViewBuilder private var card: some View {
        switch kind {
        case .uploading(let count, let progress):
            PaperBanner(
                systemImage: "arrow.up.doc",
                title: count == 1
                    ? Text("Uploading PDF", bundle: #bundle) : Text("Uploading \(count) PDFs", bundle: #bundle),
                message: Text(progress, format: .percent.precision(.fractionLength(0))),
                progress: progress
            )
        case .failed(let fileName, let error, let others):
            PaperBanner(
                systemImage: "exclamationmark.circle.fill",
                title: Text("PDF not added", bundle: #bundle),
                message: message(fileName: fileName, error: error, others: others),
                style: .error,
                actionTitle: Text("Dismiss", bundle: #bundle),
                action: onDismiss
            )
        }
    }

    private func message(fileName: String, error: PdfUploadError, others: Int) -> Text {
        var line = "\(fileName) · \(String(localized: LibraryStrings.uploadError(error)))"
        if others > 0 { line += " " + String(localized: "(+\(others) more)", bundle: #bundle) }
        return Text(verbatim: line)
    }
}
