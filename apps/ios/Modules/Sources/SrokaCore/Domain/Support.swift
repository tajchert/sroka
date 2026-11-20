import Dependencies

// Conventions for every domain protocol in this folder:
// - Android `Flow<T>` becomes `AsyncStream<T>`. Each call/access returns a NEW stream that emits the
//   current value first and then every change, so several consumers can observe independently.
// - Android `suspend fun` becomes `async`. Expected failures are result enums, not `throws`.
// - Every key's `testValue` is an unimplemented double that reports an issue, so a test that forgets
//   to override a dependency fails loudly. Previews and tests install the fakes from `SrokaTesting`
//   (`DependencyValues.useFakes()`); the composition roots install the live implementations.

extension AsyncStream where Element: Sendable {
    /// A stream that finishes immediately (unimplemented doubles).
    public static var finished: AsyncStream<Element> { AsyncStream { $0.finish() } }

    /// A stream that emits `value` and finishes.
    public static func just(_ value: Element) -> AsyncStream<Element> {
        AsyncStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }
}

/// Reports an unimplemented call on a `testValue` double.
func reportUnimplemented(_ method: String, key: String) {
    reportIssue("\(method) called without overriding \\.\(key) in this test.")
}
