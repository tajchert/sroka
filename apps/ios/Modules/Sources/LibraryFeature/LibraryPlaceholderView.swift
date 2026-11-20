import SrokaDesign
import SwiftUI

/// Placeholder screen until the LibraryFeature stream lands. Replace this file.
public struct LibraryPlaceholderView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            String(localized: "My List", bundle: #bundle),
            systemImage: "hammer",
            description: Text("Coming soon", bundle: #bundle)
        )
        .background(SrokaColor.background)
    }
}

#Preview {
    LibraryPlaceholderView()
}
