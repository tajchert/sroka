import SwiftUI

/// Paper status card (sync state, offline, errors): icon, title, optional message, optional
/// progress and one optional action. Content surface, so never glass.
public struct PaperBanner: View {
    public enum Style: Sendable, Hashable {
        case neutral
        case warning
        case error
    }

    private let systemImage: String
    private let title: Text
    private let message: Text?
    private let progress: Double?
    private let style: Style
    private let actionTitle: Text?
    private let action: (() -> Void)?

    public init(
        systemImage: String,
        title: Text,
        message: Text? = nil,
        progress: Double? = nil,
        style: Style = .neutral,
        actionTitle: Text? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.progress = progress
        self.style = style
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(foreground)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                title.font(.subheadline.weight(.semibold))
                if let message {
                    message.font(.footnote)
                }
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .tint(SrokaColor.primary)
                        .padding(.top, 2)
                }
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(action: action) {
                    actionTitle
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 6)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SrokaColor.primary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(background, in: .rect(cornerRadius: SrokaMetrics.largeRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        switch style {
        case .neutral: SrokaColor.onSurface
        case .warning: SrokaColor.warning
        case .error: SrokaColor.onErrorContainer
        }
    }

    private var background: Color {
        switch style {
        case .neutral: SrokaColor.surfaceContainer
        case .warning: SrokaColor.warningContainer
        case .error: SrokaColor.errorContainer
        }
    }
}
