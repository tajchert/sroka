import SwiftUI

/// Liquid Glass helpers. Chrome (bars, toolbars, sheets) uses system glass automatically; these
/// cover the few custom floating surfaces. Never put glass on list rows or cards.
extension View {
    /// Floating capsule of regular glass: reader bottom bar, toast, end-of-article card.
    public func floatingGlass() -> some View {
        glassEffect(.regular, in: .capsule)
    }

    /// Floating rounded rectangle of regular glass (larger floating panels).
    public func floatingGlass(cornerRadius: CGFloat) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    /// The prominent brand-blue glass button style, reserved for Save.
    public func saveButtonStyle() -> some View {
        buttonStyle(.glassProminent).tint(SrokaColor.brand)
    }
}

/// Corner radii and spacing shared across screens (Android `Shape.kt`).
public enum SrokaMetrics {
    /// Chips and thumbnails.
    public static let smallRadius: CGFloat = 8
    /// Outlined cards.
    public static let mediumRadius: CGFloat = 12
    /// Cards and floating buttons.
    public static let largeRadius: CGFloat = 16
    /// Sheets and dialogs.
    public static let extraLargeRadius: CGFloat = 28
    /// Maximum readable column width on wide windows.
    public static let readableWidth: CGFloat = 640
    public static let spacing: CGFloat = 16
    public static let smallSpacing: CGFloat = 8
}
