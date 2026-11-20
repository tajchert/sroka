import SrokaCore
import SrokaDesign
import SwiftUI

/// Theme, font, text size and line spacing. Changes apply to the open article live (no reload) and are stored.
struct AppearanceSheet: View {
    @Bindable var model: ReaderAppearanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Appearance", bundle: #bundle)
                .font(.headline)
                .frame(maxWidth: .infinity)
            ThemeSection(selected: model.preferences.readerTheme) { theme in
                Task { await model.themeSelected(theme) }
            }
            FontSection(selected: model.preferences.readerFont) { font in
                Task { await model.fontSelected(font) }
            }
            TextSizeSection(model: model)
            SpacingSection(selected: model.preferences.readerLineSpacing) { spacing in
                Task { await model.spacingSelected(spacing) }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }
}

private struct AppearanceGroupTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title, bundle: #bundle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// Page theme swatches: Light, Sepia, Dark, Auto.
struct ThemeSection: View {
    let selected: ReaderTheme
    let onSelect: (ReaderTheme) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppearanceGroupTitle("Theme")
            HStack(spacing: 10) {
                ForEach(Self.order, id: \.self) { theme in
                    ThemeSwatch(theme: theme, isSelected: theme == selected) { onSelect(theme) }
                }
            }
        }
    }

    private static let order: [ReaderTheme] = [.light, .sepia, .dark, .auto]
}

private struct ThemeSwatch: View {
    let theme: ReaderTheme
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: SrokaMetrics.mediumRadius)
                    .fill(fill)
                    .frame(height: 52)
                    .overlay {
                        Text("Aa").font(.title3).fontWeight(.semibold).foregroundStyle(textColor)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: SrokaMetrics.mediumRadius)
                            .strokeBorder(
                                isSelected ? SrokaColor.brand : SrokaColor.outlineVariant,
                                lineWidth: isSelected ? 2.5 : 1)
                    }
                label.font(.footnote).foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var palette: ReaderPalette? {
        switch theme {
        case .light: .light
        case .sepia: .sepia
        case .dark: .dark
        case .auto: nil
        }
    }

    private var fill: AnyShapeStyle {
        if let palette { return AnyShapeStyle(palette.background) }
        // Auto: half light, half dark.
        return AnyShapeStyle(
            LinearGradient(
                stops: [
                    .init(color: ReaderPalette.light.background, location: 0.5),
                    .init(color: ReaderPalette.dark.background, location: 0.5),
                ], startPoint: .leading, endPoint: .trailing))
    }

    private var textColor: Color { palette?.text ?? .gray }

    @ViewBuilder private var label: some View {
        switch theme {
        case .light: Text("Light", bundle: #bundle)
        case .sepia: Text("Sepia", bundle: #bundle)
        case .dark: Text("Dark", bundle: #bundle)
        case .auto: Text("Auto", bundle: #bundle)
        }
    }
}

/// Serif / Sans.
struct FontSection: View {
    let selected: ReaderFont
    let onSelect: (ReaderFont) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppearanceGroupTitle("Font")
            Picker(selection: Binding(get: { selected }, set: onSelect)) {
                Text("Serif", bundle: #bundle).tag(ReaderFont.serif)
                Text("Sans", bundle: #bundle).tag(ReaderFont.sans)
            } label: {
                Text("Font", bundle: #bundle)
            }
            .pickerStyle(.segmented)
        }
    }
}

/// Nine-step slider with smaller / larger "Aa" ends.
struct TextSizeSection: View {
    @Bindable var model: ReaderAppearanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppearanceGroupTitle("Size")
            HStack(spacing: 12) {
                Button {
                    Task { await model.textSizeStepperTapped(direction: -1) }
                } label: {
                    Text("Aa", bundle: #bundle).font(.footnote)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Smaller text", bundle: #bundle))
                Slider(value: $model.textSizeStop, in: 0...Double(ReaderTextScale.lastIndex), step: 1) {
                    Text("Size", bundle: #bundle)
                }
                .accessibilityValue(
                    Text("\(ReaderTextScale.px(model.preferences.readerTextScale)) pixels", bundle: #bundle))
                Button {
                    Task { await model.textSizeStepperTapped(direction: 1) }
                } label: {
                    Text("Aa", bundle: #bundle).font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Larger text", bundle: #bundle))
            }
        }
    }
}

/// Tight / Normal / Loose.
struct SpacingSection: View {
    let selected: ReaderLineSpacing
    let onSelect: (ReaderLineSpacing) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppearanceGroupTitle("Spacing")
            Picker(selection: Binding(get: { selected }, set: onSelect)) {
                Text("Tight", bundle: #bundle).tag(ReaderLineSpacing.tight)
                Text("Normal", bundle: #bundle).tag(ReaderLineSpacing.normal)
                Text("Loose", bundle: #bundle).tag(ReaderLineSpacing.loose)
            } label: {
                Text("Spacing", bundle: #bundle)
            }
            .pickerStyle(.segmented)
        }
    }
}

extension View {
    /// Presents a sheet at the height of its content.
    func fittedSheetDetent(_ height: Binding<CGFloat>) -> some View {
        self
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                height.wrappedValue = $0
            }
            .presentationDetents([.height(max(height.wrappedValue, 200))])
            .presentationDragIndicator(.visible)
    }
}
