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
        let syncOutcome = Mutex<PushSyncOutcome>(.synced(pulled: 2))
        let remaining = Mutex(false)
        /// When true, the download runs until it is cancelled.
        let blockDownload = Mutex(false)

        var steps: SyncPushHandler.Steps {
            SyncPushHandler.Steps(
                ready: { self.log.add("ready") },
                reloadStores: { self.log.add("reload") },
                isSignedIn: { self.signedIn.withLock { $0 } },
                requestSync: { self.log.add("requestSync") },
                holding: { body in
                    self.log.add("hold")
                    await body()
                    self.log.add("release")
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
                },
                needsBackgroundDownload: { self.remaining.withLock { $0 } },
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

    @Test func `In the foreground a push only requests the normal sync`() async {
        let script = Script()
        let result = await script.handler().handle(foreground: true)
        #expect(result == .newData)
        #expect(script.log.all == ["ready", "reload", "requestSync"])
    }

    @Test func `A failed sync downloads nothing and reports failure`() async {
        let script = Script()
        script.syncOutcome.withLock { $0 = .failed }
        let result = await script.handler().handle(foreground: false)
        #expect(result == .failed)
        #expect(!script.log.all.contains("download"))
    }

    @Test func `Nothing pulled reports no data`() async {
        let script = Script()
        script.syncOutcome.withLock { $0 = .synced(pulled: 0) }
        #expect(await script.handler().handle(foreground: false) == .noData)
        #expect(script.log.all.contains("download"))
    }

    @Test func `Downloads cut off by the deadline go to the processing task`() async {
        let script = Script()
        script.blockDownload.withLock { $0 = true }
        script.remaining.withLock { $0 = true }
        let result = await script.handler(deadline: .milliseconds(50)).handle(foreground: false)
        // The sync itself finished, so its data counts.
        #expect(result == .newData)
        #expect(
            script.log.all == [
                "ready", "reload", "hold", "sync", "download", "download cancelled", "release", "scheduleDownload",
            ])
    }

    @Test func `No download is scheduled when nothing is left`() async {
        let script = Script()
        _ = await script.handler().handle(foreground: false)
        #expect(!script.log.all.contains("scheduleDownload"))
    }

    @Test(arguments: [
        (SyncOutcome.success(pulledItems: 3), PushSyncOutcome.synced(pulled: 3)),
        (.skipped, .skipped),
        (.failure(.network), .failed),
        (.cancelled, .cancelled),
    ])
    func `Sync outcomes map to push outcomes`(outcome: SyncOutcome, expected: PushSyncOutcome) {
        #expect(LiveGraph.pushOutcome(outcome) == expected)
    }
}

extension SyncPushTests {
    @Test func `A handler stuck before the work returns at the hard limit and schedules the download`() async {
        let script = Script()
        let steps = script.steps
        var stuck = steps
        stuck.ready = {
            script.log.add("ready")
            // Launch recovery that never finishes.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let handler = SyncPushHandler(steps: stuck, deadline: .milliseconds(30), grace: .milliseconds(30))
        let result = await handler.handle(foreground: false)
        #expect(result == .failed)
        #expect(script.log.all.first == "ready")
        #expect(script.log.all.contains("scheduleDownload"))
        #expect(!script.log.all.contains("sync"))
    }
}
