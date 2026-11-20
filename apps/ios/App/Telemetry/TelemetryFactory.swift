import FirebaseCore
import Foundation
import SrokaCore

/// The telemetry the app starts with (repo-root D15): Firebase in a release build that carries a real
/// `GoogleService-Info.plist`, `NoTelemetry` in every other case, with no Firebase work at all in that case.
///
/// No-op when: the build is Debug; the plist is absent from the bundle (builds without
/// `Config/GoogleService-Info.plist`); it is the placeholder (`sroka-example`); it is incomplete; or its bundle id
/// is not this app's (a Dev build never reports into the production data stream).
///
/// The composition root wraps the result in `ConsentGatedTelemetry` and starts `ConsentApplier` with it; until
/// that applies the stored consent, Firebase collects nothing (Info.plist defaults are off).
func makeTelemetry(bundle: Bundle = .main) -> any Telemetry {
    #if DEBUG
        return NoTelemetry()
    #else
        let url = bundle.url(forResource: "GoogleService-Info", withExtension: "plist")
        let verdict = FirebaseConfigCheck.verdict(
            plist: url.flatMap { try? Data(contentsOf: $0) },
            bundleIdentifier: bundle.bundleIdentifier)
        guard verdict == .usable, let path = url?.path, let options = FirebaseOptions(contentsOfFile: path),
            let telemetry = FirebaseTelemetry(options: options)
        else { return NoTelemetry() }
        return telemetry
    #endif
}
