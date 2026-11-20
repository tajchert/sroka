import Clocks
import Dependencies
import Foundation
import SrokaCore
import SrokaTesting
import Synchronization

@testable import ReaderFeature

/// A date the test moves by hand (the reader's 2 s save rule reads `\.date`).
final class TestNow: Sendable {
    private let box: Mutex<Date>

    init(_ date: Date = Fixtures.now) { box = Mutex(date) }

    var value: Date { box.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        box.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

final class IntentLog: Sendable {
    private let box = Mutex<[ReaderIntent]>([])

    var all: [ReaderIntent] { box.withLock { $0 } }

    func append(_ intent: ReaderIntent) { box.withLock { $0.append(intent) } }
}

/// One reader view model on fakes, a `TestClock` and a hand-driven date.
@MainActor
final class ReaderHarness {
    let fakes: Fakes
    let clock = TestClock<Duration>()
    let now = TestNow()
    let intents = IntentLog()
    let model: ReaderViewModel
    private var observing: Task<Void, Never>?

    init(
        itemId: String,
        items: [Item] = Fixtures.items,
        preferences: UserPreferences = UserPreferences(),
        syncStatus: SyncStatus = SyncStatus()
    ) {
        let fakes = Fakes(items: items, preferences: preferences, syncStatus: syncStatus)
        let clock = clock
        let now = now
        let intents = intents
        self.fakes = fakes
        model = withDependencies {
            $0.useFakes(fakes)
            $0.continuousClock = clock
            $0.date = DateGenerator { now.value }
        } operation: {
            ReaderViewModel(itemId: itemId, onIntent: { intents.append($0) })
        }
    }

    /// Starts following the item, as the view's `.task` does.
    func start() {
        observing = Task { await model.observe() }
    }

    func stop() {
        observing?.cancel()
        model.stop()
    }

    /// Lets queued main-actor work (stream deliveries, timers registering their sleep) run.
    func idle() async {
        for _ in 0..<100 { await Task.yield() }
        // Stream deliveries hop through the real executor; give them a moment of real time as well.
        try? await Task.sleep(for: .milliseconds(5))
        for _ in 0..<100 { await Task.yield() }
    }

    /// Waits (bounded, up to about five seconds of real time) until `condition` holds; returns whether it did.
    func until(_ condition: () -> Bool) async -> Bool {
        for step in 0..<5000 {
            if condition() { return true }
            if step < 200 {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        return condition()
    }

    func item(_ id: String) -> Item? { fakes.library.item(id: id) }
}

extension ReaderViewModel {
    var readyDocument: ReaderDocument? {
        if case .ready(let document) = state { return document }
        return nil
    }

    var pdfFile: URL? {
        if case .pdfReady(let file) = state { return file }
        return nil
    }
}

/// A one-off article for state tests.
func makeItem(
    id: String,
    contentId: String? = "c-test",
    parseStatus: ParseStatus = .ok,
    parseError: String? = nil,
    offline: OfflineState = .availableRemote
) -> Item {
    Item(
        id: id,
        url: "https://example.com/\(id)",
        title: "Test article",
        siteName: "Example",
        readingMinutes: 4,
        contentId: contentId,
        parseStatus: parseStatus,
        parseError: parseError,
        savedAt: Fixtures.now,
        offline: offline
    )
}
