import SrokaDesign
import SwiftUI

extension EnvironmentValues {
    /// Snapshot tests set this: Liquid Glass buttons and `PasteButton` (a remote view) render blank
    /// through `layer.render`, so they swap to plain bordered stand-ins of the same size.
    @Entry var usesFlatControls = false
}

private struct GlassControlStyle: ViewModifier {
    let prominent: Bool
    @Environment(\.usesFlatControls) private var isFlat

    func body(content: Content) -> some View {
        if isFlat {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        } else if prominent {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

/// Tinted prominent glass in a toolbar (the + and Save buttons); plain text/symbol in snapshot tests,
/// where tinted toolbar glass renders the whole screen blank.
private struct ToolbarAccentStyle: ViewModifier {
    let isSave: Bool
    @Environment(\.usesFlatControls) private var isFlat

    func body(content: Content) -> some View {
        if isFlat {
            content.buttonStyle(.borderless)
        } else if isSave {
            content.saveButtonStyle()
        } else {
            content.buttonStyle(.glassProminent).tint(SrokaColor.primary)
        }
    }
}

extension View {
    /// The tinted + button of the My List toolbar.
    func toolbarAddStyle() -> some View { modifier(ToolbarAccentStyle(isSave: false)) }

    /// `saveButtonStyle()` in a toolbar.
    func toolbarSaveStyle() -> some View { modifier(ToolbarAccentStyle(isSave: true)) }

    /// `.glass` (or `.glassProminent`), flat in snapshot tests.
    func glassControl(prominent: Bool = false) -> some View {
        modifier(GlassControlStyle(prominent: prominent))
    }
}

/// System paste button (no clipboard permission prompt); a plain button in snapshot tests.
struct PasteLinkButton: View {
    let onPaste: ([String]) -> Void
    @Environment(\.usesFlatControls) private var isFlat

    var body: some View {
        if isFlat {
            Button {
            } label: {
                Label {
                    Text(verbatim: "Paste")
                } icon: {
                    Image(systemName: "doc.on.clipboard")
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(SrokaColor.primary)
        } else {
            PasteButton(payloadType: String.self, onPaste: onPaste)
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .tint(SrokaColor.primary)
        }
    }
}
