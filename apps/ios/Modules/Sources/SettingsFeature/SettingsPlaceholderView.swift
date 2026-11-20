import SrokaDesign
import SwiftUI

/// Placeholder screen until the SettingsFeature stream lands. Replace this file.
public struct SettingsPlaceholderView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            String(localized: "Settings", bundle: #bundle),
            systemImage: "hammer",
            description: Text("Coming soon", bundle: #bundle)
        )
        .background(SrokaColor.background)
    }
}

#Preview {
    SettingsPlaceholderView()
}
