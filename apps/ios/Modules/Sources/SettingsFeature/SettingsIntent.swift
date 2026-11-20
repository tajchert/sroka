import Foundation

/// What the app root must do when Settings asks to leave. Settings never navigates anywhere else
/// than its own pushed screens (Import, Export).
public enum SettingsIntent: Sendable, Hashable {
    /// "Done": dismiss the settings sheet.
    case dismissed
    /// Signed out or account deleted: local data is wiped and the session is gone. Dismiss the sheet;
    /// the root shows sign-in.
    case signedOut
}
