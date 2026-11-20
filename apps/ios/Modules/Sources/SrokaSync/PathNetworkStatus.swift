import Network

/// `NetworkStatus` from `NWPathMonitor` (Android `NetworkMonitor`): online while the current path is
/// satisfied. Each stream owns its monitor and starts with the current path.
public struct PathNetworkStatus: NetworkStatus {
    public init() {}

    public func observeOnline() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: .global(qos: .utility))
        }
    }
}
