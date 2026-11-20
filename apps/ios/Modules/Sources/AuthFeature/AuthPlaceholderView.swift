import SrokaDesign
import SwiftUI

/// Placeholder screen until the AuthFeature stream lands. Replace this file.
public struct AuthPlaceholderView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            String(localized: "Sign in", bundle: #bundle),
            systemImage: "hammer",
            description: Text("Coming soon", bundle: #bundle)
        )
        .background(SrokaColor.background)
    }
}

#Preview {
    AuthPlaceholderView()
}
