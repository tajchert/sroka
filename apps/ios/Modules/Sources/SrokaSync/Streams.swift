import Foundation
import GRDB
import Synchronization
import os

let syncLog = Logger(subsystem: "app.sroka", category: "sync")

/// A current value plus every change, broadcast to any number of `AsyncStream` subscribers. Each
/// `stream()` starts with the current value. Values are yielded under the lock, so every subscriber
/// sees changes in order.
final class ValueSubject<Value: Sendable & Equatable>: Sendable {
    private struct State {
        var value: Value
        var nextId = 0
        var subscribers: [Int: AsyncStream<Value>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(_ value: Value) { state = Mutex(State(value: value)) }

    var value: Value { state.withLock { $0.value } }

    /// Sets the value and notifies subscribers (equal values are dropped).
    func send(_ value: Value) {
        state.withLock { state in
            guard state.value != value else { return }
            state.value = value
            for continuation in state.subscribers.values { continuation.yield(value) }
        }
    }

    func stream() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            let id = state.nextId
            state.nextId += 1
            state.subscribers[id] = continuation
            continuation.yield(state.value)
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }
}

/// Hot one-shot events: delivered to the subscribers present when `send` runs, never replayed.
final class EventSubject<Event: Sendable>: Sendable {
    private struct State {
        var nextId = 0
        var subscribers: [Int: AsyncStream<Event>.Continuation] = [:]
    }

    private let state = Mutex(State())

    func send(_ event: Event) {
        state.withLock { state in
            for continuation in state.subscribers.values { continuation.yield(event) }
        }
    }

    /// Subscribes now: events sent after this call returns are delivered.
    func stream() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let id = state.withLock { state in
            let id = state.nextId
            state.nextId += 1
            state.subscribers[id] = continuation
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }
}

extension AsyncStream where Element: Sendable {
    /// Bridges a GRDB observation. A database error ends the stream (and is logged without detail).
    static func observing(_ makeObservation: @escaping @Sendable () -> AsyncValueObservation<Element>) -> Self {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in makeObservation() { continuation.yield(value) }
                } catch is CancellationError {
                } catch {
                    syncLog.error("observation failed: \(String(describing: type(of: error)), privacy: .public)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Wall-clock milliseconds since 1970.
@Sendable public func systemNowMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
