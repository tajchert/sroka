import Dependencies
import Foundation
import Observation
import SrokaCore

/// First-run analytics consent (repo-root D15; Android `ConsentPromptViewModel`). The app root
/// presents the prompt while `isPending` is true (see `View.consentPrompt(_:)`); either button
/// records the decision, which makes `isPending` false.
@Observable @MainActor
public final class ConsentPromptViewModel {
    public static let privacyPolicyURL = URL(string: "https://sroka.app/privacy")!

    /// True until the user decided, and only in builds that carry telemetry.
    public var isPending = false

    @ObservationIgnored @Dependency(\.consentRepository) private var consent
    @ObservationIgnored @Dependency(\.telemetry) private var telemetry

    public init() {}

    public func task() async {
        for await value in consent.consent {
            isPending = telemetry.isAvailable && value.analytics == nil
        }
    }

    public func allowTapped() async { await consent.setAnalytics(true) }
    public func declineTapped() async { await consent.setAnalytics(false) }
}
