import SrokaDesign
import SwiftUI

/// Placeholder screen until the ShareFeature stream lands. Replace this file.
public struct SharePlaceholderView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            String(localized: "Save to Sroka", bundle: #bundle),
            systemImage: "hammer",
            description: Text("Coming soon", bundle: #bundle)
        )
        .background(SrokaColor.background)
    }
}

#Preview {
    SharePlaceholderView()
}
