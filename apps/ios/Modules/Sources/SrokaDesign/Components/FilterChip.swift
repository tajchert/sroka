import SwiftUI

/// Capsule filter chip (Favorites, Under 10 min, #tag). Selected chips use the tinted container
/// colour; the hit target is at least 44 pt tall.
public struct FilterChip: View {
    private let title: Text
    private let systemImage: String?
    private let isSelected: Bool
    private let action: () -> Void

    public init(_ title: Text, systemImage: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption.weight(.semibold))
                }
                title.font(.chip)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .foregroundStyle(isSelected ? SrokaColor.onPrimaryContainer : SrokaColor.onSurface)
            .background(isSelected ? SrokaColor.primaryContainer : SrokaColor.surfaceContainer, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
