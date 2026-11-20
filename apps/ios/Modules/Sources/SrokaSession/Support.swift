import Foundation
import SrokaNetwork
import Synchronization

/// A thread-safe current value observed by any number of `AsyncStream`s: each stream emits the current value first,
/// then every change that differs from the previous one.
final class CurrentValue<Value: Sendable & Equatable>: Sendable {
    private struct State {
        var value: Value
        var observers: [UUID: AsyncStream<Value>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(_ value: Value) {
        state = Mutex(State(value: value))
    }

    var value: Value { state.withLock { $0.value } }

    /// Replaces the value; observers hear about it only when it changed.
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

/// The outcome of one API call, with every thrown error folded into `ApiError`.
enum ApiOutcome<T: Sendable>: Sendable {
    case success(T)
    case failure(ApiError)
}

/// Runs an API call. `CancellationError` (or anything else unexpected) counts as a transport failure, so callers have
/// exactly one error model.
func apiCall<T: Sendable>(_ body: () async throws -> T) async -> ApiOutcome<T> {
    do {
        return .success(try await body())
    } catch let error as ApiError {
        return .failure(error)
    } catch {
        return .failure(.transport(.cancelled))
    }
}

/// Waits for `operation` at most `timeout` on `clock`, then returns regardless. The operation keeps no hold on the
/// caller after the timeout: it is cancelled and left to finish on its own, so an operation that ignores cancellation
/// cannot block the caller.
func runWithTimeout(
    _ timeout: Duration,
    clock: any Clock<Duration>,
    _ operation: @escaping @Sendable () async -> Void
) async {
    let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let resumeOnce: @Sendable () -> Void = {
        gate.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }
    }
    var tasks: [Task<Void, Never>] = []
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        gate.withLock { $0 = continuation }
        tasks.append(
            Task {
                await operation()
                resumeOnce()
            })
        tasks.append(
            Task {
                try? await clock.sleep(for: timeout)
                resumeOnce()
            })
    }
    for task in tasks { task.cancel() }
}

/// First element of a stream, or nil when it finishes empty.
func firstValue<T: Sendable>(of stream: AsyncStream<T>) async -> T? {
    for await value in stream { return value }
    return nil
}

/// Runs async bodies one at a time, in arrival order (an actor would interleave them at every `await`).
final class SerialGate: Sendable {
    private struct State {
        var busy = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let enter = state.withLock { state in
                if state.busy {
                    state.waiters.append(continuation)
                    return false
                }
                state.busy = true
                return true
            }
            if enter { continuation.resume() }
        }
    }

    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.busy = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}
