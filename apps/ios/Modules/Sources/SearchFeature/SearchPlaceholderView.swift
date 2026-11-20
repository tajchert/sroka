import SrokaDesign
import SwiftUI

/// Placeholder screen until the SearchFeature stream lands. Replace this file.
public struct SearchPlaceholderView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            String(localized: "Search", bundle: #bundle),
            systemImage: "hammer",
            description: Text("Coming soon", bundle: #bundle)
        )
        .background(SrokaColor.background)
    }
}

#Preview {
    SearchPlaceholderView()
}
