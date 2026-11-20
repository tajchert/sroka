import Foundation
import Synchronization

/// Serializes async work per key (one download per item at a time, so the bulk run and the reader never race).
actor KeyedLock {
    private var held = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withLock<T: Sendable>(_ key: String, _ body: @Sendable () async -> T) async -> T {
        await acquire(key)
        let result = await body()
        release(key)
        return result
    }

    private func acquire(_ key: String) async {
        if held.insert(key).inserted { return }
        // Ownership is handed over by `release`, so `held` keeps the key.
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    private func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            held.remove(key)
        }
    }
}

/// A current value plus every change, for any number of `AsyncStream` observers (each gets the current value
/// first, per the SrokaCore protocol convention).
final class Broadcast<Value: Sendable>: Sendable {
    private struct State {
        var value: Value
        var next = 0
        var continuations: [Int: AsyncStream<Value>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(_ value: Value) {
        state = Mutex(State(value: value))
    }

    var value: Value { state.withLock { $0.value } }

    func update(_ change: (inout Value) -> Void) {
        // Yielding never blocks; doing it under the lock keeps observers in update order.
        state.withLock { state in
            change(&state.value)
            for continuation in state.continuations.values { continuation.yield(state.value) }
        }
    }

    func stream() -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = state.withLock { state in
                let id = state.next
                state.next += 1
                state.continuations[id] = continuation
                continuation.yield(state.value)
                return id
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
            }
        }
    }
}
