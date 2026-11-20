import SrokaDesign
import SwiftUI

/// Blocking screen shown instead of the app when this build is too old to run. No navigation, no data access.
struct UpdateRequiredView: View {
    let storeURL: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 56))
                .foregroundStyle(SrokaColor.brand)
                .accessibilityHidden(true)
            Text("Update needed")
                .font(.brandHeading(.title2))
                .accessibilityAddTraits(.isHeader)
            Text("This version of Sroka is no longer supported. Update the app to keep reading.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
            if let storeURL {
                Button {
                    openURL(storeURL)
                } label: {
                    Text("Update").frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .tint(SrokaColor.brand)
                .controlSize(.large)
                .accessibilityIdentifier("update.button")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SrokaColor.background)
    }
}

#Preview {
    UpdateRequiredView(storeURL: URL(string: "https://apps.apple.com/app/id0"))
}
