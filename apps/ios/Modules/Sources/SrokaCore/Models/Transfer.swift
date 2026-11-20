import Foundation

/// Server import formats (api.md §11.1); the raw value is the `format` form field.
public enum ImportFormat: String, Sendable, Hashable, CaseIterable {
    case pocketCsv = "pocket_csv"
    case pocketHtml = "pocket_html"
    case instapaperCsv = "instapaper_csv"
    case netscapeHtml = "netscape_html"

    public init?(wire: String?) {
        guard let wire, let value = Self(rawValue: wire) else { return nil }
        self = value
    }
}

/// `GET /v1/exports?format=` (api.md §11.2); raw value is the query value and the file extension.
public enum ExportFormat: String, Sendable, Hashable, CaseIterable {
    case csv
    case json

    public var fileExtension: String { rawValue }
}

/// api.md §4.3: `queued -> running -> done | failed`.
public enum JobStatus: String, Sendable, Hashable {
    case queued
    case running
    case done
    case failed

    /// Unknown future values are treated as still running.
    public init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .running }

    public var isFinished: Bool { self == .done || self == .failed }
}

/// An import job (api.md §4.3). `total` is nil until the file is parsed; `error` is a server code
/// such as `too_many_rows`.
public struct ImportJob: Sendable, Hashable, Identifiable {
    public var id: String
    public var status: JobStatus
    public var format: ImportFormat
    public var total: Int?
    public var done: Int
    public var skipped: Int
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        status: JobStatus,
        format: ImportFormat,
        total: Int? = nil,
        done: Int = 0,
        skipped: Int = 0,
        error: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.status = status
        self.format = format
        self.total = total
        self.done = done
        self.skipped = skipped
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
