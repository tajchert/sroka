import Foundation
import SrokaCore

/// What an item row shows besides the title: one status (highest priority wins), the read state and
/// the "site · reading time" line. Pure and view-model free so the component, the continue-reading
/// cards and tests share it. Android: `ItemRow.kt`.
public struct ItemRowPresentation: Sendable, Hashable {
    public enum Status: Sendable, Hashable, CaseIterable {
        case waitingToSync
        case preparing
        case failed
        case previewOnly
        case partialCopy
        case downloading
        case notOnDevice

        /// SF Symbol of the status badge on the thumbnail.
        public var symbolName: String {
            switch self {
            case .waitingToSync: "arrow.triangle.2.circlepath"
            case .preparing: "ellipsis"
            case .failed: "exclamationmark.circle.fill"
            case .previewOnly: "lock.fill"
            case .partialCopy: "exclamationmark.triangle.fill"
            case .downloading: "arrow.down"
            case .notOnDevice: "icloud.slash"
            }
        }

        /// The same words Android shows (`Vocabulary`).
        public var label: String {
            switch self {
            case .waitingToSync: String(localized: "Waiting to sync", bundle: #bundle)
            case .preparing: String(localized: "Preparing…", bundle: #bundle)
            case .failed: String(localized: "Couldn’t save the text", bundle: #bundle)
            case .previewOnly: String(localized: "Preview only", bundle: #bundle)
            case .partialCopy: String(localized: "Partial copy", bundle: #bundle)
            case .downloading: String(localized: "Downloading", bundle: #bundle)
            case .notOnDevice: String(localized: "Not on this device", bundle: #bundle)
            }
        }

        /// Statuses spelled out in the meta line; the others are badge-only.
        var isSpelledOut: Bool {
            switch self {
            case .downloading, .notOnDevice: false
            default: true
            }
        }
    }

    public enum ReadState: Sendable, Hashable {
        case unread
        case inProgress
        case read
    }

    public var status: Status?
    public var readState: ReadState
    public var progress: Double
    public var isPDF: Bool
    /// "example.com · 7 min left", "PDF · 2.3 MB"; spells out text statuses.
    public var metaText: String

    public init(_ item: ItemSummary) {
        status = Self.status(of: item)
        readState = Self.readState(progress: item.progress)
        progress = item.progress
        isPDF = item.kind == .pdf
        metaText = Self.metaText(of: item, status: status, readState: readState)
    }

    public var showsProgressBar: Bool { readState == .inProgress }
    public var showsRetry: Bool { status == .failed }

    /// Spoken label of the whole row (the row is one accessibility element).
    public func accessibilityLabel(title: String) -> String {
        var parts = [title, metaText]
        if readState == .inProgress {
            parts.append(String(localized: "\(Int((progress * 100).rounded()))% read", bundle: #bundle))
        }
        if let status, !status.isSpelledOut { parts.append(status.label) }
        return parts.joined(separator: ", ")
    }

    static func status(of item: ItemSummary) -> Status? {
        if item.pendingChange != nil { return .waitingToSync }
        switch item.parseStatus {
        case .failed: return .failed
        case .partial: return item.parseError == "paywalled" ? .previewOnly : .partialCopy
        case .pending: return .preparing
        case .ok: break
        }
        switch item.offline {
        case .downloading, .queued: return .downloading
        case .availableRemote: return .notOnDevice
        case .none, .downloaded, .failed: return nil
        }
    }

    static func readState(progress: Double) -> ReadState {
        if progress >= 0.98 { return .read }
        if progress >= 0.02 { return .inProgress }
        return .unread
    }

    static func metaText(of item: ItemSummary, status: Status?, readState: ReadState) -> String {
        var parts: [String] = []
        if item.kind == .pdf {
            if let size = item.fileSize, size > 0 {
                parts.append(String(localized: "PDF · \(formatFileSize(size))", bundle: #bundle))
            } else {
                parts.append(String(localized: "PDF", bundle: #bundle))
            }
        } else {
            if !item.domain.isEmpty { parts.append(item.domain) }
            switch readState {
            case .read: parts.append("✓ " + String(localized: "Read", bundle: #bundle))
            case .inProgress:
                if let minutes = item.readingMinutes {
                    parts.append(
                        String(localized: "\(minutesLeft(minutes, progress: item.progress)) min left", bundle: #bundle))
                }
            case .unread:
                if let minutes = item.readingMinutes {
                    parts.append(String(localized: "\(minutes) min", bundle: #bundle))
                }
            }
        }
        if let status, status.isSpelledOut { parts.append(status.label) }
        return parts.joined(separator: " · ")
    }

    /// Minutes still to read, at least 1 (Android `minutesLeft`).
    public static func minutesLeft(_ minutes: Int, progress: Double) -> Int {
        max(1, Int((Double(minutes) * (1 - progress) - 1e-6).rounded(.up)))
    }

    /// Decimal units like Android: "2.3 MB", "820 KB", "90 B".
    public static func formatFileSize(_ bytes: Int64) -> String {
        if bytes >= 1_000_000 {
            return String(
                localized: "\((Double(bytes) / 1_000_000).formatted(.number.precision(.fractionLength(1)))) MB",
                bundle: #bundle)
        }
        if bytes >= 1_000 {
            return String(localized: "\(Int((Double(bytes) / 1_000).rounded())) KB", bundle: #bundle)
        }
        return String(localized: "\(bytes) B", bundle: #bundle)
    }
}
