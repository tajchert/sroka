import Dependencies
import Foundation

/// Uploads PDFs from the device to `POST /v1/items/pdf`. Each file is copied into the App Group
/// `pdf-uploads/` directory, then uploaded by a background `URLSession` task. After a successful
/// upload a sync pull brings the item into the library through the normal path. Android: PdfUploader.kt.
public protocol PdfUploader: Sendable {
    /// All uploads known to the app, oldest first: in flight, plus finished ones until `clearFinished`.
    var uploads: AsyncStream<[PdfUpload]> { get }

    /// Copies each file (document picker, share sheet or drop; security-scoped URLs) into app storage
    /// and enqueues an upload. Files that fail the client checks (over 50 MiB, no `%PDF-` header,
    /// device storage full, unreadable) come back as `.failed` entries. Returns entries in input order.
    func enqueue(_ fileURLs: [URL]) async -> [PdfUpload]

    /// Cancels a queued/running upload and deletes its temp copy. No-op for finished ones.
    func cancel(id: String) async

    /// Forgets finished uploads (done / permanently failed), e.g. after the toast was shown.
    func clearFinished()
}

private struct UnimplementedPdfUploader: PdfUploader {
    private func fail(_ method: String) { reportUnimplemented("PdfUploader.\(method)", key: "pdfUploader") }

    var uploads: AsyncStream<[PdfUpload]> {
        fail("uploads")
        return .finished
    }
    func enqueue(_ fileURLs: [URL]) async -> [PdfUpload] {
        fail("enqueue")
        return []
    }
    func cancel(id: String) async { fail("cancel") }
    func clearFinished() { fail("clearFinished") }
}

private enum PdfUploaderKey: TestDependencyKey {
    static let testValue: any PdfUploader = UnimplementedPdfUploader()
}

extension DependencyValues {
    public var pdfUploader: any PdfUploader {
        get { self[PdfUploaderKey.self] }
        set { self[PdfUploaderKey.self] = newValue }
    }
}
