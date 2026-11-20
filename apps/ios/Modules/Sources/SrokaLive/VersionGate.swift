import Foundation
import Observation

/// The build number in `CFBundleVersion` ("42", or "42.1" where the leading number counts), or nil when it has none.
/// `/v1/config` `minVersions.ios` is compared against this number.
public func buildNumber(fromBundleVersion bundleVersion: String?) -> Int? {
    guard let bundleVersion else { return nil }
    let digits = bundleVersion.trimmingCharacters(in: .whitespaces).prefix(while: \.isASCIIDigit)
    return digits.isEmpty ? nil : Int(digits)
}

/// True only when both numbers are known and this build is below the server's minimum. An unknown build or a missing
/// minimum never blocks the app.
public func isUpdateRequired(build: Int?, minimum: Int?) -> Bool {
    guard let build, let minimum else { return false }
    return build < minimum
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Reads `minVersions.ios` from `/v1/config` and says whether this build must be updated before it can be used.
///
/// Checked at launch, when the app becomes active and when the session changes. A failed check (offline, server error)
/// keeps the last answer for the same server, so a device that once learned it is too old stays blocked until a later
/// check says otherwise. Answers belong to the server they came from: a switch drops the old answer, and a reply that
/// arrives after a switch is ignored.
@Observable @MainActor
public final class VersionGate {
    /// The outcome of one config read: the minimum (nil when the server sets none), or nil when the read failed.
    public typealias FetchMinimum = @Sendable () async -> Int??

    /// The root view shows the blocking "Update Sroka" screen while this is true.
    public private(set) var updateRequired = false
    /// The minimum the server asked for when `updateRequired` became true (for diagnostics, never shown).
    public private(set) var minimumBuild: Int?

    @ObservationIgnored private let build: Int?
    @ObservationIgnored private let server: @Sendable () -> String
    @ObservationIgnored private let fetchMinimum: FetchMinimum
    @ObservationIgnored private var inFlight: (id: Int, server: String, task: Task<Void, Never>)?
    @ObservationIgnored private var latestRequest = 0
    @ObservationIgnored private var answeredServer: String?

    /// - Parameter server: the effective server requests go to now (the key answers are stored under).
    public init(
        build: Int?, server: @escaping @Sendable () -> String = { "" }, fetchMinimum: @escaping FetchMinimum
    ) {
        self.build = build
        self.server = server
        self.fetchMinimum = fetchMinimum
    }

    /// A gate that never blocks (UI tests, previews).
    public static func alwaysSupported() -> VersionGate {
        VersionGate(build: nil, fetchMinimum: { nil })
    }

    /// One config read; concurrent calls for the same server share it.
    public func check() async {
        let key = server()
        if let answeredServer, answeredServer != key { forget() }
        if let inFlight, inFlight.server == key {
            await inFlight.task.value
            return
        }
        let fetch = fetchMinimum
        latestRequest += 1
        let id = latestRequest
        let task = Task { @MainActor [weak self] in
            let result = await fetch()
            // Only the newest request publishes, and only if the server is still the one it was made for.
            guard let self, self.latestRequest == id, self.server() == key else { return }
            // A failed read keeps the previous answer.
            guard case .some(let minimum) = result else { return }
            self.answeredServer = key
            self.minimumBuild = minimum
            self.updateRequired = isUpdateRequired(build: self.build, minimum: minimum)
        }
        inFlight = (id, key, task)
        await task.value
        if inFlight?.id == id { inFlight = nil }
    }

    private func forget() {
        answeredServer = nil
        minimumBuild = nil
        updateRequired = false
    }
}
