import Dependencies
import Foundation
import Observation
import SrokaCore
import SrokaDesign

/// The palette actually applied to the article; `ReaderTheme.auto` resolves to light or dark.
/// Colours come from `ReaderPalette` (plan "Colour"), so native chrome and the page agree exactly.
enum EffectiveTheme: String, Sendable, CaseIterable {
    case light
    case sepia
    case dark

    /// Value of the page's `data-theme` attribute.
    var cssName: String { rawValue }

    var palette: ReaderPalette {
        switch self {
        case .light: .light
        case .sepia: .sepia
        case .dark: .dark
        }
    }

    var isDark: Bool { self == .dark }

    static func resolve(_ theme: ReaderTheme, systemDark: Bool) -> EffectiveTheme {
        switch theme {
        case .auto: systemDark ? .dark : .light
        case .light: .light
        case .sepia: .sepia
        case .dark: .dark
        }
    }
}

extension ReaderFont {
    /// Value of the page's `data-font` attribute (the stacks live in the reader CSS).
    var cssName: String {
        switch self {
        case .sans: "sans"
        case .serif: "serif"
        }
    }
}

extension ReaderLineSpacing {
    /// Unitless CSS line height; `.normal` is the original 1.65.
    var lineHeight: Double {
        switch self {
        case .tight: 1.45
        case .normal: 1.65
        case .loose: 1.9
        }
    }
}

/// Text size: 9 steps from 0.8 to 1.6 over an 18 px base (independent of Dynamic Type, as on Android).
enum ReaderTextScale {
    static let basePx = 18.0
    static let stepCount = 9
    static let range = UserPreferences.readerTextScaleRange
    static var lastIndex: Int { stepCount - 1 }

    static func scale(at index: Int) -> Double {
        let step = (range.upperBound - range.lowerBound) / Double(lastIndex)
        let clamped = min(max(index, 0), lastIndex)
        return ((range.lowerBound + Double(clamped) * step) * 100).rounded() / 100
    }

    static func index(of scale: Double) -> Int {
        let step = (range.upperBound - range.lowerBound) / Double(lastIndex)
        let raw = (UserPreferences.clampTextScale(scale) - range.lowerBound) / step
        return min(max(Int(raw.rounded()), 0), lastIndex)
    }

    /// CSS body size in px for `scale`.
    static func px(_ scale: Double) -> Int { Int((basePx * scale).rounded()) }
}

/// Reader theme, font, size and spacing: observed from `SettingsRepository`, written optimistically
/// (the page restyles at once; the stored value follows). Shared by the reader and the appearance sheet.
@Observable @MainActor
public final class ReaderAppearanceModel {
    public private(set) var preferences = UserPreferences()
    /// False until the stored preferences have arrived (the page is not loaded before, to avoid a restyle flash).
    public private(set) var isLoaded = false

    @ObservationIgnored @Dependency(\.settingsRepository) private var settings

    public init() {}

    /// Follows the stored preferences until cancelled.
    public func observe() async {
        for await value in settings.preferences {
            preferences = value
            isLoaded = true
        }
    }

    func themeSelected(_ theme: ReaderTheme) async {
        preferences.readerTheme = theme
        await settings.setReaderTheme(theme)
    }

    func fontSelected(_ font: ReaderFont) async {
        preferences.readerFont = font
        await settings.setReaderFont(font)
    }

    func spacingSelected(_ spacing: ReaderLineSpacing) async {
        preferences.readerLineSpacing = spacing
        await settings.setReaderLineSpacing(spacing)
    }

    /// `index` is a slider stop, 0 ... 8.
    func textSizeStepSelected(_ index: Int) async {
        let scale = ReaderTextScale.scale(at: index)
        guard scale != preferences.readerTextScale else { return }
        preferences.readerTextScale = scale
        await settings.setReaderTextScale(scale)
    }

    /// The slider position as a stop value. The setter is for the bound slider only.
    var textSizeStop: Double {
        get { Double(ReaderTextScale.index(of: preferences.readerTextScale)) }
        set { Task { await textSizeStepSelected(Int(newValue.rounded())) } }
    }

    func textSizeStepperTapped(direction: Int) async {
        await textSizeStepSelected(ReaderTextScale.index(of: preferences.readerTextScale) + direction)
    }
}
