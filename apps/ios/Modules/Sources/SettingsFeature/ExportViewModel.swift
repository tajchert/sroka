import Dependencies
import Foundation
import Observation
import SrokaCore

/// A built export, ready to share or save.
public struct ReadyExport: Sendable, Hashable {
    public var fileURL: URL
    public var fileName: String
    public var bytes: Int64
}

/// Library export as CSV or JSON (Android `ExportViewModel`).
@Observable @MainActor
public final class ExportViewModel {
    public private(set) var format: ExportFormat = .json
    public private(set) var isExporting = false
    public private(set) var ready: ReadyExport?
    public private(set) var error: ExportError?
    /// Result line of the last "Save" (saved / could not save).
    public private(set) var saveMessage: LocalizedStringResource?
    /// Presentation state of the system "save to Files" sheet.
    public var isSavingFile = false

    @ObservationIgnored @Dependency(\.dataTransferRepository) private var transfer

    public init() {}

    public func formatSelected(_ format: ExportFormat) {
        guard !isExporting else { return }
        // A different format invalidates the built file.
        self.format = format
        ready = nil
        error = nil
        saveMessage = nil
    }

    public func exportTapped() async {
        guard !isExporting else { return }
        isExporting = true
        ready = nil
        error = nil
        saveMessage = nil
        let result = await transfer.export(format: format)
        isExporting = false
        switch result {
        case .ready(let fileURL, let fileName, let bytes):
            ready = ReadyExport(fileURL: fileURL, fileName: fileName, bytes: bytes)
        case .failed(let reason):
            error = reason
        }
    }

    public func saveTapped() {
        guard ready != nil else { return }
        isSavingFile = true
    }

    /// Result of the "save to Files" sheet. A cancelled sheet says nothing.
    public func fileSaved(_ result: Result<URL, any Error>) {
        switch result {
        case .success:
            saveMessage = LocalizedStringResource("Saved", bundle: #bundle)
        case .failure(let failure):
            if (failure as? CocoaError)?.code == .userCancelled { return }
            saveMessage = LocalizedStringResource("Could not save the file.", bundle: #bundle)
        }
    }

    public var errorMessage: LocalizedStringResource? {
        guard let error else { return nil }
        switch error {
        case .network:
            return LocalizedStringResource("No connection. Check your network and try again.", bundle: #bundle)
        case .signedOut:
            return LocalizedStringResource("Your session has expired. Sign in again to export.", bundle: #bundle)
        case .server:
            return LocalizedStringResource(
                "The server could not build the export. Try again in a little while.",
                bundle: #bundle
            )
        }
    }
}
