/// Why a PDF upload failed. Mapped to strings in the UI; never carries raw error text.
public enum PdfUploadError: String, Sendable, Hashable {
    /// Over `Limits.maxPdfBytes` (client check or HTTP 413). Permanent.
    case tooLarge
    /// No `%PDF-` header (client check or HTTP 415). Permanent.
    case notPdf
    /// Account PDF quota (HTTP 409 `storage_full`) or no space left on this device. Permanent.
    case storageFull
    /// Connectivity problem that lasted through all retries.
    case network
    /// Server error or unexpected answer.
    case unknown
    /// Session expired (HTTP 401).
    case auth
}

public enum PdfUploadState: Sendable, Hashable {
    /// Copied locally and waiting for a network / a free slot.
    case queued
    /// Streaming to the server; `progress` is 0...1 of bytes sent.
    case uploading(progress: Double)
    /// Permanent failure: the temp copy is deleted, nothing retries.
    case failed(PdfUploadError)
    /// `itemId` is the library item (new or the existing duplicate); `duplicate` = already saved.
    case done(itemId: String?, duplicate: Bool)
}

/// One PDF upload as the UI shows it ("Uploading N PDFs" row, toast).
public struct PdfUpload: Sendable, Hashable, Identifiable {
    public var id: String
    public var fileName: String
    public var sizeBytes: Int64
    public var state: PdfUploadState

    public init(id: String, fileName: String, sizeBytes: Int64, state: PdfUploadState) {
        self.id = id
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.state = state
    }

    /// Still in flight: queued or uploading.
    public var isActive: Bool {
        switch state {
        case .queued, .uploading: true
        case .failed, .done: false
        }
    }
}
