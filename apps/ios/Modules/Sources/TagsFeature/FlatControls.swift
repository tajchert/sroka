import SrokaDesign
import SwiftUI

extension EnvironmentValues {
    /// Snapshot tests set this: Liquid Glass buttons render blank through `layer.render`, so they
    /// swap to plain bordered stand-ins of the same size.
    @Entry var usesFlatTagControls = false
}

/// The brand-blue Save button (`saveButtonStyle()`), flat in snapshot tests.
private struct SaveControlStyle: ViewModifier {
    @Environment(\.usesFlatTagControls) private var isFlat

    func body(content: Content) -> some View {
        if isFlat {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(SrokaColor.brand)
        } else {
            content.saveButtonStyle()
        }
    }
}

extension View {
    func saveControl() -> some View { modifier(SaveControlStyle()) }
}
