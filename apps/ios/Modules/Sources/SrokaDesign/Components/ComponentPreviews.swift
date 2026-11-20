import SrokaCore
import SwiftUI

#Preview("Item rows") {
    let now = Date(timeIntervalSince1970: 1_793_784_600)
    List {
        ItemRow(
            ItemSummary(
                id: "1", displayTitle: "The slow web: why reading later still matters", domain: "example.com",
                readingMinutes: 17, isFavorite: true, progress: 0.42, savedAt: now)
        )
        ItemRow(
            ItemSummary(
                id: "2", displayTitle: "Market outlook", domain: "paper.example.com", parseStatus: .failed, savedAt: now
            ),
            onRetry: {}
        )
        ItemRow(
            ItemSummary(
                id: "3", displayTitle: "Annual report", domain: "files.example.com", savedAt: now, kind: .pdf,
                fileSize: 3_145_728)
        )
    }
    .listStyle(.plain)
}

#Preview("Chips, banner and toast") {
    VStack(spacing: 16) {
        HStack {
            FilterChip(Text(verbatim: "Favorites"), systemImage: "star", isSelected: false) {}
            FilterChip(Text(verbatim: "Under 10 min"), systemImage: "clock", isSelected: true) {}
        }
        PaperBanner(
            systemImage: "arrow.down.circle", title: Text(verbatim: "Downloading for offline"),
            message: Text(verbatim: "2 of 5"),
            progress: 0.4)
        GlassToast(Text(verbatim: "Archived"), actionTitle: Text(verbatim: "Undo")) {}
    }
    .padding()
}
