import Foundation
import SrokaCore
import SrokaSync
import Synchronization
import Testing

@testable import SrokaLive

@Suite struct SyncPushTests {
    /// Scripted steps that record their order.
    final class Script: Sendable {
        let log = StepLog()
        let signedIn = Mutex(true)
        let syncOutcome = Mutex<PushSyncOutcome>(.synced(changed: true))
        let downloaded = Mutex(false)
        let remaining = Mutex(false)
        let automatic = Mutex(true)
        /// When true, the download runs until it is cancelled.
        let blockDownload = Mutex(false)

        var steps: SyncPushHandler.Steps {
            SyncPushHandler.Steps(
                ready: { self.log.add("ready") },
                reloadStores: { self.log.add("reload") },
                isSignedIn: { self.signedIn.withLock { $0 } },
                hold: {
                    self.log.add("hold")
                    return { self.log.add("release") }
                },
                sync: {
                    self.log.add("sync")
                    return self.syncOutcome.withLock { $0 }
                },
                download: {
                    self.log.add("download")
                    if self.blockDownload.withLock({ $0 }) {
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                        self.log.add("download cancelled")
                    }
                    return self.downloaded.withLock { $0 }
                },
                needsBackgroundDownload: { self.remaining.withLock { $0 } },
                automaticDownloads: { self.automatic.withLock { $0 } },
                scheduleDownload: { self.log.add("scheduleDownload") })
        }

        func handler(deadline: Duration = .seconds(25)) -> SyncPushHandler {
            SyncPushHandler(steps: steps, deadline: deadline)
        }
    }

    @Test func `A sync message is recognised by its type only`() {
        #expect(SyncPushMessage.isSync(["aps": ["content-available": 1], "type": "sync"]))
        #expect(!SyncPushMessage.isSync(["aps": ["content-available": 1]]))
        #expect(!SyncPushMessage.isSync(["type": "other"]))
        #expect(!SyncPushMessage.isSync(["type": 1]))
    }

    @Test func `In the background a push syncs, then downloads, inside a database hold`() async {
        let script = Script()
        let result = await script.handler().handle(foreground: false)
        #expect(result == .newData)
        #expect(script.log.all == ["ready", "reload", "hold", "sync", "download", "release"])
    }

    @Test func `Signed out, a push does nothing`() async {
        let script = Script()
        script.signedIn.withLock { $0 = false }
        let result = await script.handler().handle(foreground: false)
        #expect(result == .noData)
        #expect(script.log.all == ["ready", "reload"])
    }

    @Test func `In the foreground a push syncs and leaves downloads to the app's own run`() async {
        let script = Script()
        let result = await script.handler().handle(foreground: true)
        #expect(result == .newData)
        #expect(script.log.all == ["ready", "reload", "hold", "sync", "release"])
    }

    @Test func `A failed sync downloads nothing and reports failure`() async {
        let script = Script()
        script.syncOutcome.withLock { $0 = .failed }
        let result = await script.handler().handle(foreground: false)
        #expect(result == .failed)
        #expect(!script.log.all.contains("download"))
    }

    @Test func `The result reports committed changes or completed downloads`() async {
        let script = Script()
        script.syncOutcome.withLock { $0 = .synced(changed: false) }
        #expect(await script.handler().handle(foreground: false) == .noData)
        script.downloaded.withLock { $0 = true }
        #expect(await script.handler().handle(foreground: false) == .newData)
    }

    @Test func `Downloads cut off by the deadline go to the processing task`() async {
        let script = Script()
        script.blockDownload.withLock { $0 = true }
        let result = await script.handler(deadline: .milliseconds(50)).handle(foreground: false)
        // The sync itself finished, so its data counts.
        #expect(result == .newData)
        #expect(
            script.log.all == [
                "ready", "reload", "hold", "sync", "download", "download cancelled", "scheduleDownload", "release",
            ])
    }

    @Test func `Under Manual nothing is handed to the processing task`() async {
        let script = Script()
        script.automatic.withLock { $0 = false }
        script.blockDownload.withLock { $0 = true }
        _ = await script.handler(deadline: .milliseconds(50)).handle(foreground: false)
        #expect(!script.log.all.contains("scheduleDownload"))
    }

    @Test func `No download is scheduled when nothing is left`() async {
        let script = Script()
        _ = await script.handler().handle(foreground: false)
        #expect(!script.log.all.contains("scheduleDownload"))
        script.remaining.withLock { $0 = true }
        _ = await script.handler().handle(foreground: false)
        #expect(script.log.all.contains("scheduleDownload"))
    }

    @Test(arguments: [
        (SyncOutcome.success(pulledItems: 3), false, PushSyncOutcome.synced(changed: true)),
        (.success(pulledItems: 0), true, .synced(changed: true)),
        (.success(pulledItems: 0), false, .synced(changed: false)),
        (.skipped, false, .skipped),
        (.failure(.network), false, .failed),
        (.cancelled, false, .cancelled),
    ])
    func `Sync outcomes map to push outcomes`(outcome: SyncOutcome, cursorMoved: Bool, expected: PushSyncOutcome) {
        #expect(LiveGraph.pushOutcome(outcome, cursorMoved: cursorMoved) == expected)
    }
}

extension SyncPushTests {
    @Test(.timeLimit(.minutes(1)))
    func `A handler stuck before the work returns at the hard limit and schedules the download`() async {
        let script = Script()
        let (unstuck, unstick) = AsyncStream<Void>.makeStream()
        defer { unstick.yield() }
        var stuck = script.steps
        stuck.ready = {
            script.log.add("ready")
            // Launch recovery that ignores cancellation.
            await Task.detached { for await _ in unstuck { break } }.value
        }
        let handler = SyncPushHandler(steps: stuck, deadline: .milliseconds(30), grace: .milliseconds(30))
        let result = await handler.handle(foreground: false)
        #expect(result == .failed)
        #expect(script.log.all.first == "ready")
        #expect(script.log.all.contains("scheduleDownload"))
        #expect(!script.log.all.contains("sync"))
        #expect(!script.log.all.contains("hold"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `The push's hold is released before it returns, even while its work is stuck`() async throws {
        let script = Script()
        let (unstuck, unstick) = AsyncStream<Void>.makeStream()
        var stuck = script.steps
        stuck.sync = {
            script.log.add("sync")
            // Ignores cancellation (a database wait that is not cancellable).
            await Task.detached { for await _ in unstuck { break } }.value
            script.log.add("sync returned")
            return .failed
        }
        let handler = SyncPushHandler(steps: stuck, deadline: .milliseconds(30), grace: .milliseconds(30))
        let result = await handler.handle(foreground: false)
        #expect(result == .failed)
        #expect(script.log.all == ["ready", "reload", "hold", "sync", "release", "scheduleDownload"])
        unstick.yield()
        try await waitFor { script.log.all.contains("sync returned") }
        try await Task.sleep(for: .milliseconds(20))
        // The late end of the work releases nothing twice.
        #expect(script.log.all.filter { $0 == "release" }.count == 1)
    }
}
