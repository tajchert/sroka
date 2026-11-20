import CoreText
import SwiftUI
import Synchronization

/// Type styles. Body copy uses SF through text styles (Dynamic Type for free); Outfit SemiBold is
/// only for brand headings (wordmark, onboarding, empty states), scaled with `relativeTo:`.
public enum SrokaFont {
    /// Family name of the bundled `Resources/Fonts/Outfit.ttf` (variable font).
    public static let brandFamily = "Outfit"

    private static let registered = Mutex(false)

    /// Registers the bundled fonts with the process. Idempotent; call once at launch (app and share
    /// extension composition roots) and in previews/snapshots before rendering brand headings.
    @discardableResult
    public static func registerFonts() -> Bool {
        registered.withLock { done in
            if done { return true }
            guard let url = Bundle.module.url(forResource: "Outfit", withExtension: "ttf") else { return false }
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            // Already registered (e.g. by another target in the same process) also counts as success.
            done = ok || error != nil
            return done
        }
    }

    /// Outfit SemiBold at the size of `style`, scaling with Dynamic Type.
    public static func brandHeading(_ style: Font.TextStyle = .title) -> Font {
        .custom(brandFamily, size: baseSize(style), relativeTo: style).weight(.semibold)
    }

    /// Default (large size category) point sizes of the iOS text styles.
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .extraLargeTitle2: 28
        case .extraLargeTitle: 36
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }
}

extension Font {
    /// Outfit SemiBold brand heading (see `SrokaFont.brandHeading`).
    public static func brandHeading(_ style: Font.TextStyle = .title) -> Font { SrokaFont.brandHeading(style) }

    /// Item row title.
    public static let rowTitle = Font.headline
    /// Domain · reading time line under a row title.
    public static let rowMeta = Font.subheadline
    /// Excerpt / snippet text.
    public static let rowExcerpt = Font.callout
    /// Tag chips and small labels.
    public static let chip = Font.footnote.weight(.medium)
}
