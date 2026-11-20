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
    @ObservationIgnored private let serverChanges: @Sendable () -> AsyncStream<String>
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var serverObservation: Task<Void, Never>?

    /// - Parameter serverChanges: the effective server, current value first; a change triggers a version check.
    public init(
        sessionStates: @escaping @Sendable () -> AsyncStream<SessionState>,
        serverChanges: @escaping @Sendable () -> AsyncStream<String> = { AsyncStream { $0.finish() } },
        versionGate: VersionGate,
        deepLinks: DeepLinkInbox
    ) {
        self.sessionStates = sessionStates
        self.serverChanges = serverChanges
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

    /// Starts following the session and the server. Idempotent.
    public func start() {
        guard observation == nil else { return }
        let servers = serverChanges()
        serverObservation = Task { [weak self] in
            var last: String?
            for await server in servers {
                let changed = last != nil && last != server
                last = server
                // Switching servers while signed out changes no session: check the new server's minimum here.
                if changed { await self?.versionGate.check() }
            }
        }
        let stream = sessionStates()
        observation = Task { [weak self] in
            for await state in stream {
                guard let self else { return }
                guard self.session != state else { continue }
                let changed = self.session != nil
                self.session = state
                // Sign-in, sign-out and server switches change the session: the server may be another one now.
                if changed { Task { await self.versionGate.check() } }
            }
        }
    }
}
