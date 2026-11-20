import Dependencies

/// Local telemetry consent (repo-root D15). Android: ConsentRepository.kt.
public protocol ConsentRepository: Sendable {
    /// Current consent; emits immediately (defaults when nothing is stored).
    var consent: AsyncStream<Consent> { get }

    /// Records the analytics decision (also dismisses the first-run prompt).
    func setAnalytics(_ enabled: Bool) async

    func setCrashReports(_ enabled: Bool) async
}

private struct UnimplementedConsentRepository: ConsentRepository {
    private func fail(_ method: String) { reportUnimplemented("ConsentRepository.\(method)", key: "consentRepository") }

    var consent: AsyncStream<Consent> {
        fail("consent")
        return .finished
    }
    func setAnalytics(_ enabled: Bool) async { fail("setAnalytics") }
    func setCrashReports(_ enabled: Bool) async { fail("setCrashReports") }
}

private enum ConsentRepositoryKey: TestDependencyKey {
    static let testValue: any ConsentRepository = UnimplementedConsentRepository()
}

extension DependencyValues {
    public var consentRepository: any ConsentRepository {
        get { self[ConsentRepositoryKey.self] }
        set { self[ConsentRepositoryKey.self] = newValue }
    }
}
