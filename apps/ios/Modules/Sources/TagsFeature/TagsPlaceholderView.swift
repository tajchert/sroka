import SrokaDesign
import SwiftUI

/// Placeholder screen until the TagsFeature stream lands. Replace this file.
public struct TagsPlaceholderView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            String(localized: "Tags", bundle: #bundle),
            systemImage: "hammer",
            description: Text("Coming soon", bundle: #bundle)
        )
        .background(SrokaColor.background)
    }
}

#Preview {
    TagsPlaceholderView()
}
