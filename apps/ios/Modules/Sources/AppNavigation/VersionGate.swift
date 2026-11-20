import Foundation

/// Whether this build may run at all. A blocking gate replaces the whole app with the "update needed" screen;
/// it wins over the session root, a held deep link and every sheet.
public enum VersionGate: Sendable, Equatable {
    case open
    /// The server (or a minimum version setting) no longer supports this build.
    case updateRequired(storeURL: URL?)

    public var isBlocking: Bool {
        switch self {
        case .open: false
        case .updateRequired: true
        }
    }
}
