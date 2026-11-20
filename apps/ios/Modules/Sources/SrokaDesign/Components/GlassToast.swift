import SwiftUI

/// Transient confirmation: a glass capsule with a message and at most one action ("Undo").
/// The owner positions it above the tab bar, times it out and announces it to VoiceOver.
public struct GlassToast: View {
    private let message: Text
    private let actionTitle: Text?
    private let action: (() -> Void)?

    public init(_ message: Text, actionTitle: Text? = nil, action: (() -> Void)? = nil) {
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 6) {
            message
                .font(.subheadline.weight(.medium))
                .foregroundStyle(SrokaColor.onSurface)
                .lineLimit(2)
                .padding(.leading, 6)
            if let actionTitle, let action {
                Button(action: action) {
                    actionTitle
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(SrokaColor.primary)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .floatingGlass()
        .accessibilityElement(children: .contain)
    }
}
