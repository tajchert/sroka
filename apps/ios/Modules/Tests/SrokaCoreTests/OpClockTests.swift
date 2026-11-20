import Synchronization
import Testing

@testable import SrokaCore

private final class MemoryClockStore: OpClockStore {
    private let value: Mutex<Int64>
    init(_ value: Int64 = 0) { self.value = Mutex(value) }
    func load() -> Int64 { value.withLock { $0 } }
    func save(_ newValue: Int64) { value.withLock { $0 = newValue } }
}

struct OpClockTests {
    @Test func `Is strictly increasing within one millisecond`() {
        let clock = OpClock(now: { 100 })
        #expect([clock.next(), clock.next(), clock.next()] == [100, 101, 102])
    }

    @Test func `Follows the wall clock when it moves ahead`() {
        let now = Mutex<Int64>(100)
        let clock = OpClock(now: { now.withLock { $0 } })
        #expect(clock.next() == 100)
        now.withLock { $0 = 500 }
        #expect(clock.next() == 500)
    }

    @Test func `Does not go backwards when the clock does`() {
        let now = Mutex<Int64>(1_000)
        let clock = OpClock(now: { now.withLock { $0 } })
        #expect(clock.next() == 1_000)
        now.withLock { $0 = 10 }
        #expect(clock.next() == 1_001)
    }

    @Test func `Observing a later remote time moves the clock past it`() {
        let clock = OpClock(now: { 100 })
        clock.observe(900)
        #expect(clock.next() == 901)
        clock.observe(5)
        #expect(clock.next() == 902)
    }

    @Test func `Persists the last value and resumes from it`() {
        let store = MemoryClockStore()
        let first = OpClock(now: { 100 }, store: store)
        _ = first.next()
        _ = first.next()
        #expect(store.load() == 101)
        let restarted = OpClock(now: { 50 }, store: store)
        #expect(restarted.next() == 102)
        restarted.observe(700)
        #expect(store.load() == 700)
    }
}
