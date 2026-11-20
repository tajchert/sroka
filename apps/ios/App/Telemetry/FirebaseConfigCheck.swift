import Foundation

/// Decides whether a bundled `GoogleService-Info.plist` is a real Firebase config this build may report into.
/// Foundation only (no Firebase import), so the rule can be compiled and checked on its own.
/// The same rule is mirrored in `scripts/release-preflight.sh`.
enum FirebaseConfigCheck {
    /// Substring of the project id (and of every value) in `Config/GoogleService-Info.example.plist`.
    /// Assembled at runtime so the literal is not in the app binary: `scripts/release-preflight.sh` rejects any
    /// bundle that contains it, the binary included.
    static let placeholderMarker = ["sroka", "example"].joined(separator: "-")

    enum Verdict: Equatable {
        case usable
        case missing
        case unreadable
        case placeholder
        case incomplete
        case bundleMismatch
    }

    /// `plist` is the file's bytes (nil = absent from the bundle); `bundleIdentifier` is this app's own id.
    static func verdict(plist: Data?, bundleIdentifier: String?) -> Verdict {
        guard let plist else { return .missing }
        guard
            let object = try? PropertyListSerialization.propertyList(from: plist, format: nil),
            let values = object as? [String: Any]
        else { return .unreadable }

        let strings = values.values.compactMap { $0 as? String }
        if strings.contains(where: { $0.localizedCaseInsensitiveContains(placeholderMarker) }) {
            return .placeholder
        }
        for key in ["API_KEY", "GOOGLE_APP_ID", "PROJECT_ID", "BUNDLE_ID"] {
            guard let value = values[key] as? String, !value.isEmpty else { return .incomplete }
        }
        // A Dev build (app.sroka.dev) must not report into the production app's data stream.
        guard values["BUNDLE_ID"] as? String == bundleIdentifier else { return .bundleMismatch }
        return .usable
    }
}
