import SrokaDesign
import SwiftUI

/// First-run "Help improve Sroka?" prompt. The app root attaches it with `.consentPrompt(model)`.
public struct ConsentPromptView: View {
    let model: ConsentPromptViewModel

    public init(model: ConsentPromptViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.largeTitle)
                .foregroundStyle(SrokaColor.brand)
                .accessibilityHidden(true)
            Text("Help improve Sroka?", bundle: #bundle)
                .font(.brandHeading(.title2))
                .accessibilityAddTraits(.isHeader)
            Text(
                "Share anonymous usage statistics (which features are used, never what you read) via Google Analytics. You can change this anytime in Settings.",
                bundle: #bundle
            )
            .font(.body)
            .foregroundStyle(SrokaColor.onSurfaceVariant)
            Link(destination: ConsentPromptViewModel.privacyPolicyURL) {
                Text("Privacy policy", bundle: #bundle)
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.allowTapped() }
            } label: {
                Text("Allow", bundle: #bundle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(SrokaColor.brand)
            .controlSize(.large)
            .accessibilityIdentifier("consent.allow")
            Button {
                Task { await model.declineTapped() }
            } label: {
                Text("No thanks", bundle: #bundle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("consent.decline")
        }
        .padding(24)
        .frame(maxWidth: 480, maxHeight: .infinity, alignment: .topLeading)
        .background(SrokaColor.background)
        .tint(SrokaColor.brand)
    }
}

extension View {
    /// Presents the consent prompt as a sheet while the user has not decided. Either button decides.
    public func consentPrompt(_ model: ConsentPromptViewModel) -> some View {
        modifier(ConsentPromptModifier(model: model))
    }
}

private struct ConsentPromptModifier: ViewModifier {
    @Bindable var model: ConsentPromptViewModel

    func body(content: Content) -> some View {
        content
            .task { await model.task() }
            .sheet(isPresented: $model.isPending) {
                ConsentPromptView(model: model)
                    .presentationDetents([.medium])
                    .interactiveDismissDisabled()
            }
    }
}
