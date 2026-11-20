import Foundation
import Observation
import SrokaCore

/// Which top-level screen the app shows.
public enum RootScreen: Sendable, Hashable {
    /// The session has not been read yet (first frame only).
    case launching
    /// This build is below the server's minimum: a blocking "Update Sroka" screen.
    case updateRequired
    case signedOut
    /// Signed in, or expired (the library stays readable and asks to sign in again).
    case library
}

/// App-wide observable state for the root view: session, version gate and pending deep link. One instance per
/// process, created by the composition root and put in the SwiftUI environment.
@Observable @MainActor
public final class AppModel {
    /// Current session, nil until the first value arrives.
    public private(set) var session: SessionState?
    public let versionGate: VersionGate
    public let deepLinks: DeepLinkInbox

    @ObservationIgnored private let sessionStates: @Sendable () -> AsyncStream<SessionState>
    @ObservationIgnored private var observation: Task<Void, Never>?

    public init(
        sessionStates: @escaping @Sendable () -> AsyncStream<SessionState>,
        versionGate: VersionGate,
        deepLinks: DeepLinkInbox
    ) {
        self.sessionStates = sessionStates
        self.versionGate = versionGate
        self.deepLinks = deepLinks
    }

    public var root: RootScreen {
        if versionGate.updateRequired { return .updateRequired }
        switch session {
        case nil: return .launching
        case .signedOut: return .signedOut
        case .signedIn, .expired: return .library
        }
    }

    /// Starts following the session. Idempotent.
    public func start() {
        guard observation == nil else { return }
        let stream = sessionStates()
        observation = Task { [weak self] in
            for await state in stream {
                guard let self else { return }
                if self.session != state { self.session = state }
            }
        }
    }
}
