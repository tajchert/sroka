/// Telemetry consent (repo-root D15), stored per device and never synced.
public struct Consent: Sendable, Hashable {
    /// Usage analytics opt-in; nil = not asked yet (treated as off).
    public var analytics: Bool?
    /// Crash reporting; on by default, with an opt-out.
    public var crashReports: Bool

    public init(analytics: Bool? = nil, crashReports: Bool = true) {
        self.analytics = analytics
        self.crashReports = crashReports
    }

    public var analyticsEnabled: Bool { analytics == true }
}
