import SrokaCore
import SrokaDesign
import SwiftUI

/// Shown over the bottom of the page once the article is scrolled to its end: "Finished · 9 min", the
/// archive-and-next / keep actions and the next readable item. An archived article only shows the header and
/// "Up next".
struct EndOfArticleCard: View {
    let minutes: Int?
    let isArchived: Bool
    let next: ItemSummary?
    let theme: EffectiveTheme
    let onArchive: () -> Void
    let onKeep: () -> Void
    let onOpenNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EndCardHeader(minutes: minutes)
            if !isArchived {
                EndCardActions(hasNext: next != nil, onArchive: onArchive, onKeep: onKeep)
            }
            if let next {
                EndCardUpNext(item: next, onOpen: onOpenNext)
            }
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .foregroundStyle(theme.palette.text)
        .readerGlass(theme, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
    }
}

/// Check mark and "Finished · N min".
struct EndCardHeader: View {
    let minutes: Int?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(SrokaColor.brand)
            if let minutes {
                Text("Finished · \(minutes) min", bundle: #bundle).font(.headline)
            } else {
                Text("Finished", bundle: #bundle).font(.headline)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Archive & next" (or plain "Archive" without a next item) and "Keep".
struct EndCardActions: View {
    let hasNext: Bool
    let onArchive: () -> Void
    let onKeep: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onArchive) {
                Group {
                    if hasNext {
                        Text("Archive & next", bundle: #bundle)
                    } else {
                        Text("Archive", bundle: #bundle)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(SrokaColor.brand)
            Button(action: onKeep) {
                Text("Keep", bundle: #bundle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .controlSize(.large)
    }
}

/// The next readable item: thumbnail, title and reading time.
struct EndCardUpNext: View {
    let item: ItemSummary
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up next", bundle: #bundle)
                .font(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    UpNextThumbnail(url: item.thumbnailPath)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle).font(.subheadline).fontWeight(.medium).lineLimit(2)
                        if let minutes = item.readingMinutes {
                            Text("\(minutes) min", bundle: #bundle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct UpNextThumbnail: View {
    let url: URL?

    var body: some View {
        RoundedRectangle(cornerRadius: SrokaMetrics.smallRadius)
            .fill(SrokaColor.surfaceHigh)
            .frame(width: 56, height: 56)
            .overlay {
                if let url, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: SrokaMetrics.smallRadius))
            .accessibilityHidden(true)
    }
}
