import SwiftUI

/// Sroka palette, mirroring Android `core/designsystem` (Color.kt, Theme.kt, ExtendedColors.kt).
/// Every colour adapts to light/dark through `Resources/Colors.xcassets`.
///
/// Use system materials (glass) for chrome; use these opaque paper tones for content: rows, cards,
/// reader pages. Brand blue is the accent and the Save button only.
public enum SrokaColor {
    // MARK: Surfaces
    public static let background = named("Background")
    public static let surfaceLowest = named("SurfaceLowest")
    public static let surfaceLow = named("SurfaceLow")
    public static let surfaceContainer = named("SurfaceContainer")
    public static let surfaceHigh = named("SurfaceHigh")
    public static let surfaceHighest = named("SurfaceHighest")
    public static let inverseSurface = named("InverseSurface")
    public static let inverseOnSurface = named("InverseOnSurface")

    // MARK: Content
    public static let onSurface = named("OnSurface")
    public static let onSurfaceVariant = named("OnSurfaceVariant")
    public static let outline = named("Outline")
    public static let outlineVariant = named("OutlineVariant")

    // MARK: Accents
    public static let primary = named("Primary")
    public static let onPrimary = named("OnPrimary")
    public static let primaryContainer = named("PrimaryContainer")
    public static let onPrimaryContainer = named("OnPrimaryContainer")
    public static let tertiary = named("Tertiary")
    public static let tertiaryContainer = named("TertiaryContainer")
    public static let onTertiaryContainer = named("OnTertiaryContainer")
    public static let error = named("Error")
    public static let onError = named("OnError")
    public static let errorContainer = named("ErrorContainer")
    public static let onErrorContainer = named("OnErrorContainer")

    // MARK: Extended (SrokaExtendedColors)
    /// Brand blue #1E6F8F in both appearances (logo, Save button tint).
    public static let brand = named("Brand")
    public static let onBrand = named("OnBrand")
    public static let brandYellow = named("BrandYellow")
    public static let warning = named("Warning")
    public static let warningContainer = named("WarningContainer")
    public static let progress = named("Progress")
    public static let progressTrack = named("ProgressTrack")
    public static let readerProgress = named("ReaderProgress")
    public static let readerBody = named("ReaderBody")

    /// All asset names, for tests that check every colour resolves.
    public static let assetNames = [
        "Background", "SurfaceLowest", "SurfaceLow", "SurfaceContainer", "SurfaceHigh", "SurfaceHighest",
        "InverseSurface", "InverseOnSurface", "OnSurface", "OnSurfaceVariant", "Outline", "OutlineVariant",
        "Primary", "OnPrimary", "PrimaryContainer", "OnPrimaryContainer", "Tertiary", "TertiaryContainer",
        "OnTertiaryContainer", "Error", "OnError", "ErrorContainer", "OnErrorContainer", "Brand", "OnBrand",
        "BrandYellow", "Warning", "WarningContainer", "Progress", "ProgressTrack", "ReaderProgress", "ReaderBody",
    ]

    static func named(_ name: String) -> Color { Color(name, bundle: .module) }
}

/// Fixed reader page palettes (independent of the system appearance), from Android `ReaderHtml.kt`.
public struct ReaderPalette: Sendable, Hashable {
    /// `#RRGGBB` values, also used as CSS in the reader web view.
    public var backgroundHex: String
    public var textHex: String
    public var linkHex: String

    public init(backgroundHex: String, textHex: String, linkHex: String) {
        self.backgroundHex = backgroundHex
        self.textHex = textHex
        self.linkHex = linkHex
    }

    public var background: Color { Color(hex: backgroundHex) }
    public var text: Color { Color(hex: textHex) }
    public var link: Color { Color(hex: linkHex) }

    public static let light = ReaderPalette(backgroundHex: "#FBFBF9", textHex: "#15171C", linkHex: "#1E6F8F")
    public static let sepia = ReaderPalette(backgroundHex: "#F3EAD8", textHex: "#40321F", linkHex: "#1F6F6A")
    public static let dark = ReaderPalette(backgroundHex: "#121314", textHex: "#D9D7D1", linkHex: "#7CC0DA")
}

extension Color {
    /// `#RRGGBB` in sRGB; invalid input gives clear.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .clear
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
