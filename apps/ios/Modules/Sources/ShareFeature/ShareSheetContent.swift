import SrokaCore
import SrokaDesign
import SwiftUI

extension EnvironmentValues {
    /// Snapshot tests set this: Liquid Glass buttons render blank through `layer.render`, so they
    /// swap to plain bordered stand-ins of the same size.
    @Entry var usesFlatControls = false
}

/// Callbacks of the stateless sheet content.
struct ShareSheetActions {
    var tags: () -> Void
    var favorite: () -> Void
    var open: () -> Void
    var close: () -> Void
    var signIn: () -> Void
    var touch: () -> Void

    static var none: ShareSheetActions {
        ShareSheetActions(tags: {}, favorite: {}, open: {}, close: {}, signIn: {}, touch: {})
    }
}

/// The sheet's body for one `ShareSheetState`: header, item card, actions and the countdown line.
/// Stateless, so previews and snapshots render every variant without a view model.
struct ShareSheetContent: View {
    let state: ShareSheetState
    let actions: ShareSheetActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch state.phase {
            case .saving:
                ProgressView().frame(maxWidth: .infinity, minHeight: 64)
            case .saved(_, let alreadySaved):
                if alreadySaved {
                    AlreadySavedSection(item: state.item, actions: actions)
                } else {
                    JustSavedSection(item: state.item, actions: actions)
                }
            case .noLink:
                ShareHeader(
                    symbol: "link", slashed: true, tone: .neutral,
                    title: Text("No link found in what you shared", bundle: #bundle))
            case .needsSignIn:
                ShareHeader(
                    symbol: "bookmark.fill", tone: .neutral,
                    title: Text("Sign in to Sroka to save articles", bundle: #bundle))
                ShareButton(title: Text("Sign in", bundle: #bundle), action: actions.signIn)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .needsApp:
                ShareHeader(
                    symbol: "arrow.triangle.2.circlepath", tone: .neutral,
                    title: Text("Open Sroka to finish updating", bundle: #bundle),
                    subtitle: Text("Sroka has to update its library before it can save here.", bundle: #bundle))
            case .error:
                ShareHeader(
                    symbol: "exclamationmark.triangle.fill", tone: .neutral,
                    title: Text("Couldn’t save to Sroka", bundle: #bundle),
                    subtitle: Text("Open Sroka and try again.", bundle: #bundle))
            case .pdf(let phase):
                PdfSection(phase: phase, actions: actions)
            }
            CountdownLine(countdown: state.countdown)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

// MARK: Sections

private struct JustSavedSection: View {
    let item: Item?
    let actions: ShareSheetActions

    var body: some View {
        ShareHeader(symbol: "checkmark", tone: .brand, title: Text("Saved", bundle: #bundle))
        if let item { ItemCard(item: item) }
        HStack(spacing: 8) {
            FilterChip(Text("Tags", bundle: #bundle), systemImage: "tag", isSelected: false, action: actions.tags)
                .disabled(item == nil)
            FilterChip(
                Text("Favorite", bundle: #bundle),
                systemImage: item?.isFavorite == true ? "star.fill" : "star",
                isSelected: item?.isFavorite == true,
                action: actions.favorite
            )
            .disabled(item == nil)
            Spacer(minLength: 0)
            Button(action: actions.open) {
                Text("Open", bundle: #bundle)
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 6)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(SrokaColor.primary)
        }
    }
}

private struct AlreadySavedSection: View {
    let item: Item?
    let actions: ShareSheetActions

    var body: some View {
        ShareHeader(symbol: "bookmark.fill", tone: .neutral, title: Text("Already saved", bundle: #bundle))
        if let item {
            ItemCard(item: item) {
                ReadProgressLine(item: item)
            }
        }
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(action: actions.close) {
                Text("Close", bundle: #bundle)
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(SrokaColor.primary)
            ShareButton(title: Text("Continue reading", bundle: #bundle), action: actions.open)
        }
    }
}

private struct PdfSection: View {
    let phase: ShareSheetState.PdfPhase
    let actions: ShareSheetActions

    var body: some View {
        switch phase {
        case .working:
            ProgressView().frame(maxWidth: .infinity, minHeight: 64)
        case .queued(let count):
            ShareHeader(
                symbol: "doc.fill", tone: .brand,
                title: count == 1
                    ? Text("Adding PDF to Sroka", bundle: #bundle)
                    : Text("Adding \(count) PDFs to Sroka", bundle: #bundle),
                subtitle: Text("It uploads in the background.", bundle: #bundle))
        case .duplicate:
            ShareHeader(symbol: "bookmark.fill", tone: .brand, title: Text("Already in Sroka", bundle: #bundle))
        case .added:
            ShareHeader(symbol: "checkmark", tone: .brand, title: Text("PDF added to Sroka", bundle: #bundle))
        case .failed(let error):
            ShareHeader(
                symbol: "exclamationmark.triangle.fill", tone: .neutral,
                title: Text("Couldn’t add PDF", bundle: #bundle),
                subtitle: ShareStrings.uploadError(error))
            Button(action: actions.close) {
                Text("Close", bundle: #bundle)
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(SrokaColor.primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .noFile:
            ShareHeader(symbol: "link", slashed: true, tone: .neutral, title: Text("No PDF to add", bundle: #bundle))
        }
    }
}

// MARK: Pieces

/// Round icon, a title and an optional second line.
private struct ShareHeader: View {
    enum Tone { case brand, neutral }

    let symbol: String
    var slashed = false
    let tone: Tone
    let title: Text
    var subtitle: Text?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .symbolVariant(slashed ? .slash : .none)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tone == .brand ? SrokaColor.onBrand : SrokaColor.onSurface)
                .frame(width: 38, height: 38)
                .background(tone == .brand ? SrokaColor.brand : SrokaColor.surfaceHighest, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.title3.weight(.bold)).foregroundStyle(SrokaColor.onSurface)
                if let subtitle {
                    subtitle.font(.subheadline).foregroundStyle(SrokaColor.onSurfaceVariant)
                }
            }
            .accessibilityAddTraits(.isHeader)
        }
    }
}

/// The saved item on a bordered paper card: the shared `ItemRow` (a fresh save would otherwise read
/// "Waiting to sync", which the "Saved" title already says), plus optional extra lines.
private struct ItemCard<Extra: View>: View {
    let item: Item
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ItemRow(summary)
            extra
        }
        .padding(.vertical, 2)
        .background(SrokaColor.surfaceLowest, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(SrokaColor.outlineVariant, lineWidth: 1)
        )
    }

    private var summary: ItemSummary {
        var summary = item.summary
        summary.pendingChange = nil
        return summary
    }
}

extension ItemCard where Extra == EmptyView {
    init(item: Item) {
        self.init(item: item) { EmptyView() }
    }
}

/// "42% read · 6 min left" and a thin progress bar, on the already-saved card.
private struct ReadProgressLine: View {
    let item: Item

    var body: some View {
        let progress = min(max(item.progress, 0), 1)
        let percent = Int((progress * 100).rounded())
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let minutes = item.readingMinutes {
                    Text(
                        "\(percent)% read · \(ItemRowPresentation.minutesLeft(minutes, progress: progress)) min left",
                        bundle: #bundle)
                } else {
                    Text("\(percent)% read", bundle: #bundle)
                }
            }
            .font(.subheadline)
            .foregroundStyle(SrokaColor.onSurfaceVariant)
            ReadingProgressBar(progress: progress)
                .frame(height: 4)
                .clipShape(.capsule)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

/// Glass button for the sheet's one primary action ("Sign in", "Continue reading"). Tinted glass is
/// reserved for Save, so this one is plain glass.
private struct ShareButton: View {
    let title: Text
    let action: () -> Void
    @Environment(\.usesFlatControls) private var isFlat

    var body: some View {
        if isFlat {
            Button(action: action) { label }.buttonStyle(.bordered)
        } else {
            Button(action: action) { label }.buttonStyle(.glass)
        }
    }

    private var label: some View {
        title.font(.body.weight(.semibold)).padding(.horizontal, 6)
    }
}

/// The thin line that counts the auto-dismiss down; it keeps its height when hidden so the sheet
/// does not change size on the first touch.
private struct CountdownLine: View {
    let countdown: ShareSheetState.Countdown
    @State private var fraction: Double

    init(countdown: ShareSheetState.Countdown) {
        self.countdown = countdown
        if case .frozen(let value) = countdown { fraction = value } else { fraction = 1 }
    }

    var body: some View {
        Capsule()
            .fill(SrokaColor.surfaceHigh)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(SrokaColor.primary).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 4)
            .opacity(countdown == .hidden ? 0 : 1)
            .animation(.easeOut(duration: 0.2), value: countdown == .hidden)
            .task(id: countdown) {
                switch countdown {
                case .running(let seconds, _):
                    fraction = 1
                    withAnimation(.linear(duration: seconds)) { fraction = 0 }
                case .frozen(let value):
                    fraction = value
                case .hidden:
                    break
                }
            }
            .accessibilityHidden(true)
            .padding(.top, 6)
    }
}

/// Same words as Android's upload error messages.
enum ShareStrings {
    static func uploadError(_ error: PdfUploadError) -> Text {
        switch error {
        case .tooLarge: Text("Too large. PDFs can be up to 50 MB.", bundle: #bundle)
        case .notPdf: Text("Not a PDF file.", bundle: #bundle)
        case .storageFull: Text("Storage is full.", bundle: #bundle)
        case .network: Text("No connection. Check your network.", bundle: #bundle)
        case .unknown: Text("Something went wrong. Try again later.", bundle: #bundle)
        case .auth: Text("Sign in again to upload.", bundle: #bundle)
        }
    }
}
