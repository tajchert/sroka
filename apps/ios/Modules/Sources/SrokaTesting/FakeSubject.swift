import Foundation
import Synchronization

/// A thread-safe current value that any number of `AsyncStream`s observe: each stream emits the
/// current value first, then every change. The building block of the in-memory fakes.
public final class FakeSubject<Value: Sendable>: Sendable {
    private struct State {
        var value: Value
        var observers: [UUID: @Sendable (Value) -> Void] = [:]
    }

    private let state: Mutex<State>

    public init(_ value: Value) {
        state = Mutex(State(value: value))
    }

    public var value: Value { state.withLock { $0.value } }

    public func send(_ value: Value) {
        update { $0 = value }
    }

    /// Mutates the value and notifies observers (in order, under the lock).
    public func update(_ body: (inout Value) -> Void) {
        state.withLock { state in
            body(&state.value)
            for observer in state.observers.values { observer(state.value) }
        }
    }

    public func stream() -> AsyncStream<Value> { stream { $0 } }

    /// A stream of `transform(value)`, emitted for the current value and on every change.
    public func stream<T: Sendable>(_ transform: @escaping @Sendable (Value) -> T) -> AsyncStream<T> {
        let (stream, continuation) = AsyncStream<T>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { state in
            state.observers[id] = { continuation.yield(transform($0)) }
            continuation.yield(transform(state.value))
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
        return stream
    }
}

/// Hot one-shot events: only consumers subscribed at the time of `send` receive them (no replay).
public final class FakeEvents<Event: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Event>.Continuation]>([:])

    public init() {}

    public func send(_ event: Event) {
        continuations.withLock { for continuation in $0.values { continuation.yield(event) } }
    }

    public func stream() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }
}

/// Records calls made to a fake, for assertions.
public final class CallRecorder<Call: Sendable>: Sendable {
    private let storage = Mutex<[Call]>([])

    public init() {}

    public var calls: [Call] { storage.withLock { $0 } }

    public func record(_ call: Call) {
        storage.withLock { $0.append(call) }
    }
}
