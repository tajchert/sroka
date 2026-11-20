import SrokaDesign
import SwiftUI

/// Placeholder screen until the ReaderFeature stream lands. Replace this file.
public struct ReaderPlaceholderView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            String(localized: "Reader", bundle: #bundle),
            systemImage: "hammer",
            description: Text("Coming soon", bundle: #bundle)
        )
        .background(SrokaColor.background)
    }
}

#Preview {
    ReaderPlaceholderView()
}
