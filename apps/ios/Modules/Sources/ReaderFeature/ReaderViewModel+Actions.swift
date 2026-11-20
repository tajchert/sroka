import Dependencies
import Foundation
import SrokaCore

/// Timing rules of the progress writes and the keep-awake timer (Android parity).
enum ReaderTiming {
    /// At most one save per interval while scrolling.
    static let saveInterval: Duration = .seconds(2)
    /// One more save this long after scrolling stops.
    static let saveDebounce: Duration = .seconds(1)
    static let keepAwakeIdle: Duration = .seconds(300)
    static let toastDuration: Duration = .seconds(5)
    static let refreshPoll: Duration = .seconds(4)
    static let refreshTimeout: Duration = .seconds(90)
    /// Opening below this progress is not announced ("Resumed at N%").
    static let resumeThreshold = 0.02
}

// MARK: - Progress

extension ReaderViewModel {
    /// The reader script reported a position (throttled to every 150 ms on the page side, also while
    /// flinging). Persists at most every 2 s, and once more 1 s after scrolling stops, so the final
    /// position is written (and synced) without waiting for the reader to close.
    func readingPositionReported(_ report: ProgressReport) {
        guard isReady else { return }
        reported = report
        progress = report.progress
        atEnd = report.atEnd
        unsaved = true
        touchActivity()
        trailingSave?.cancel()
        trailingSave = nil
        let now = date.now
        if let lastSavedAt, now.timeIntervalSince(lastSavedAt) < ReaderTiming.saveInterval.inSeconds {
            trailingSave = Task {
                try? await clock.sleep(for: ReaderTiming.saveDebounce)
                guard !Task.isCancelled else { return }
                saveReported(at: date.now)
            }
        } else {
            saveReported(at: now)
        }
    }

    func saveReported(at now: Date) {
        guard let report = reported, isReady, unsaved else { return }
        lastSavedAt = now
        unsaved = false
        write(report)
    }

    /// The PDF viewer's current page (0-based): progress is `(page + 1) / pageCount`, the anchor is the page
    /// index. Page changes are discrete and rare, so they are written at once (no 2 s throttle): a
    /// force-quit right after a page turn keeps the page.
    func pdfPageChanged(page: Int, pageCount: Int) {
        guard pageCount > 0, isReady else { return }
        let index = min(max(page, 0), pageCount - 1)
        let report = ProgressReport(progress: Self.pdfProgress(page: index, pageCount: pageCount), anchor: index)
        guard report != reported else { return }
        reported = report
        progress = report.progress
        unsaved = false
        lastSavedAt = date.now
        touchActivity()
        write(report)
    }

    /// Reading progress of a PDF at 0-based `page` of `pageCount`: the last page reads 1.0.
    static func pdfProgress(page: Int, pageCount: Int) -> Double {
        pageCount <= 0 ? 0 : min(max(Double(page + 1) / Double(pageCount), 0), 1)
    }

    /// Persists the latest position (and bumps last-read, even without scrolling) when the reader goes away
    /// or the app leaves the foreground. The write is unstructured: it must outlive this screen.
    func readerLeft() {
        guard isReady else { return }
        let saved = latestItem.map { ProgressReport(progress: $0.progress, anchor: $0.progressAnchor) }
        guard let report = reported ?? saved else { return }
        if reported != nil, !unsaved { return }
        trailingSave?.cancel()
        unsaved = false
        lastSavedAt = date.now
        write(report)
    }

    /// "Start over" on the resume toast: back to the top, position reset.
    func startOverTapped() {
        reported = ProgressReport(progress: 0, anchor: nil)
        progress = 0
        atEnd = false
        unsaved = false
        lastSavedAt = date.now
        toast = nil
        scrollToTopRequest += 1
        write(ProgressReport(progress: 0, anchor: nil))
    }

    /// Writes in order: each write waits for the previous one (position updates must not overtake each other).
    private func write(_ report: ProgressReport) {
        let previous = lastWrite
        lastWrite = Task { [library, itemId] in
            await previous?.value
            await library.setProgress(id: itemId, progress: report.progress, anchor: report.anchor)
        }
    }

    /// Completes when every progress write started so far has been handed to the repository (tests).
    func writesSettled() async {
        await lastWrite?.value
    }
}

// MARK: - Keep awake

extension ReaderViewModel {
    /// Any interaction (scroll, tap, page turn) keeps the screen on for another 5 minutes.
    func touchActivity() {
        keepAwake = true
        idleTask?.cancel()
        idleTask = Task {
            try? await clock.sleep(for: ReaderTiming.keepAwakeIdle)
            guard !Task.isCancelled else { return }
            keepAwake = false
        }
    }
}

// MARK: - Toasts

extension ReaderViewModel {
    func show(_ new: ReaderToast, for duration: Duration = ReaderTiming.toastDuration) {
        toast = new
        toastTask?.cancel()
        toastTask = Task {
            try? await clock.sleep(for: duration)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    func toastDismissed() {
        toastTask?.cancel()
        toast = nil
    }

    /// Offers "Start over" when the article opened part-way through.
    func announceResumeIfNeeded() {
        guard !resumeAnnounced else { return }
        resumeAnnounced = true
        let saved = restorePoint().progress
        if saved > ReaderTiming.resumeThreshold {
            show(.resumed(percent: Int((saved * 100).rounded())), for: .seconds(6))
        }
    }
}

// MARK: - Item actions

extension ReaderViewModel {
    func favoriteTapped() async {
        guard let current = item else { return }
        await library.setFavorite(id: itemId, favorite: !current.isFavorite)
    }

    /// Archives, or moves back to My List when already archived. Archiving leaves the reader.
    func archiveTapped() async {
        guard let current = item, !isLeaving else { return }
        let archive = current.status != .archived
        readerLeft()
        await library.setStatus(id: itemId, status: archive ? .archived : .unread)
        if archive {
            isLeaving = true
            onIntent(.archived(itemId: itemId))
        }
    }

    /// End-of-article "Archive & next": archives this item, then opens the item shown as "Up next" in its
    /// place, or leaves when there is none.
    func archiveAndNextTapped() async {
        guard !isLeaving else { return }
        isLeaving = true
        let next = endNext
        readerLeft()
        await library.setStatus(id: itemId, status: .archived)
        if let next {
            onIntent(.archivedAndOpenNext(archivedId: itemId, nextId: next.id))
        } else {
            onIntent(.archived(itemId: itemId))
        }
    }

    /// End-of-article "Keep": hide the card and keep reading.
    func keepTapped() {
        isEndCardKept = true
    }

    /// End-of-article "Up next" row.
    func upNextTapped() {
        guard let next = endNext else { return }
        readerLeft()
        onIntent(.openItem(next.id))
    }

    func tagsTapped() {
        onIntent(.editTags(itemId: itemId))
    }

    func appearanceTapped() {
        isAppearancePresented = true
    }

    func deleteTapped() {
        isDeleteConfirmationPresented = true
    }

    func deleteConfirmed() async {
        isDeleteConfirmationPresented = false
        isReady = false  // do not write progress for a deleted item
        await library.delete(id: itemId)
        onIntent(.deleted(itemId: itemId))
    }

    /// "Back" from states that have nothing to show (the item no longer exists).
    func closeTapped() {
        readerLeft()
        onIntent(.close)
    }
}

// MARK: - Refresh

extension ReaderViewModel {
    /// Re-fetches the article. No-op while offline or when a refresh is already running.
    func refreshTapped() async {
        guard !isOffline, refreshPhase == .none else { return }
        // Already pending: no status change will be observed to move us on, so start in the pending phase.
        refreshPhase = (latestItem ?? item)?.parseStatus == .pending ? .pending : .requested
        refreshTimeout?.cancel()
        refreshTimeout = Task {
            // The server re-parses in seconds but the app only learns through a pull: poll until settled.
            var waited = Duration.zero
            while waited < ReaderTiming.refreshTimeout {
                try? await clock.sleep(for: ReaderTiming.refreshPoll)
                guard !Task.isCancelled else { return }
                waited += ReaderTiming.refreshPoll
                syncController.requestSync()
            }
            refreshPhase = .none  // gave up waiting; no result to announce
        }
        await library.refresh(id: itemId)
    }

    /// Follows the item's parse status while a user-requested refresh runs; announces the outcome.
    func parseStatusChanged(_ status: ParseStatus?) {
        guard status != lastParseStatus else { return }
        lastParseStatus = status
        guard let status, refreshPhase != .none else { return }
        if status == .pending {
            refreshPhase = .pending
        } else if refreshPhase == .pending {
            refreshPhase = .none
            refreshTimeout?.cancel()
            switch status {
            case .ok: show(.refreshed)
            case .partial: show(.refreshedPartial)
            case .failed: show(.refreshFailed)
            case .pending: break
            }
        }
    }
}

extension Duration {
    /// Whole and fractional seconds as a `Double`.
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
