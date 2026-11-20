import Foundation
import OSLog
import Synchronization

let liveLog = Logger(subsystem: "app.sroka", category: "app")

/// A thread-safe current value: each stream emits the current value first, then every change.
final class ValueSubject<Value: Sendable & Equatable>: Sendable {
    private struct State {
        var value: Value
        var observers: [UUID: AsyncStream<Value>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(_ value: Value) {
        state = Mutex(State(value: value))
    }

    var value: Value { state.withLock { $0.value } }

    func send(_ value: Value) {
        state.withLock { state in
            guard state.value != value else { return }
            state.value = value
            for observer in state.observers.values { observer.yield(value) }
        }
    }

    func stream() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { state in
            state.observers[id] = continuation
            continuation.yield(state.value)
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
        return stream
    }
}
