import Foundation
import SrokaCore
import UniformTypeIdentifiers

/// What the user shared, after looking through the extension's attachments.
public enum SharedInput: Sendable, Equatable {
    /// A web link: the URL attachment, else the first http(s) link in shared text. `title` is the page
    /// title the sharing app supplied (nil when absent or when it is just a link).
    case link(url: String, title: String?)
    /// PDF files staged in the extension's temporary directory (size and `%PDF-` already checked).
    case pdfs([URL])
    /// Every shared PDF failed the client checks; `PdfUploadError` is the first reason.
    case rejectedPdf(PdfUploadError)
    /// Nothing usable: no web link and no PDF.
    case nothing
}

/// Reads the extension's `NSExtensionItem` attachments (the Android counterpart reads `EXTRA_TEXT`,
/// `ClipData` and `EXTRA_STREAM`). Order: a URL attachment, then the first http(s) URL inside shared
/// text, then PDF files. A `file://` URL attachment is skipped (Files shares those next to the PDF).
@MainActor
public struct ShareInputExtractor {
    private let maxPdfBytes: Int64
    private let stagingDirectory: URL

    /// - Parameters:
    ///   - maxPdfBytes: size cap for PDF files (`Limits.maxPdfBytes`, 50 MiB).
    ///   - stagingDirectory: where PDFs are copied; the file the provider hands out disappears when its
    ///     callback returns.
    public init(
        maxPdfBytes: Int64 = Limits.maxPdfBytes,
        stagingDirectory: URL = URL.temporaryDirectory.appending(path: "share-input", directoryHint: .isDirectory)
    ) {
        self.maxPdfBytes = maxPdfBytes
        self.stagingDirectory = stagingDirectory
    }

    public func extract(from items: [NSExtensionItem]) async -> SharedInput {
        let providers = items.flatMap { $0.attachments ?? [] }
        let title = Self.pageTitle(of: items)

        // 1. URL attachments.
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let text = await Self.loadText(provider, type: .url) else { continue }
            if let link = Self.link(fromAttachment: text) { return .link(url: link, title: title) }
        }

        // 2. First http(s) URL in text (also the item's own text, which some apps fill instead).
        var texts: [String] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await Self.loadText(provider, type: .plainText) { texts.append(text) }
        }
        texts += items.compactMap { $0.attributedContentText?.string }
        for text in texts {
            if let link = UrlNormalizer.extractFirstUrl(text) { return .link(url: link, title: title) }
        }

        // 3. PDF files.
        let pdfProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }
        if !pdfProviders.isEmpty { return await stagePdfs(pdfProviders) }
        return .nothing
    }

    /// Removes PDFs staged by `extract` once the uploader has copied them (and their folder when empty).
    public nonisolated static func discard(_ urls: [URL]) {
        let manager = FileManager.default
        for url in urls {
            try? manager.removeItem(at: url)
            let folder = url.deletingLastPathComponent()
            if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? manager.removeItem(at: folder)
            }
        }
    }

    // MARK: Text and links

    /// The page title of the share: the item's title unless it is only a link.
    static func pageTitle(of items: [NSExtensionItem]) -> String? {
        for item in items {
            guard let title = item.attributedTitle?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty, UrlNormalizer.extractFirstUrl(title) == nil
            else { continue }
            return title
        }
        return nil
    }

    static func link(fromAttachment text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if UrlNormalizer.isHttpUrl(trimmed) { return trimmed }
        return UrlNormalizer.extractFirstUrl(trimmed)
    }

    private static func loadText(_ provider: NSItemProvider, type: UTType) async -> String? {
        if type == .url, provider.canLoadObject(ofClass: URL.self),
            let url = await loadURLObject(provider)
        {
            return url.isFileURL ? nil : url.absoluteString
        }
        if type == .plainText, provider.canLoadObject(ofClass: String.self),
            let string = await loadStringObject(provider)
        {
            return string
        }
        return await loadLegacyItem(provider, type: type)
    }

    private static func loadURLObject(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadStringObject(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { string, _ in continuation.resume(returning: string) }
        }
    }

    /// Providers that only register raw data (some apps hand over `Data` or attributed text).
    private static func loadLegacyItem(_ provider: NSItemProvider, type: UTType) async -> String? {
        guard let value = try? await provider.loadItem(forTypeIdentifier: type.identifier) else { return nil }
        switch value {
        case let url as URL: return url.isFileURL ? nil : url.absoluteString
        case let string as String: return string
        case let attributed as NSAttributedString: return attributed.string
        case let data as Data: return String(data: data, encoding: .utf8)
        default: return nil
        }
    }

    // MARK: PDF

    private func stagePdfs(_ providers: [NSItemProvider]) async -> SharedInput {
        var staged: [URL] = []
        var firstError: PdfUploadError?
        for provider in providers {
            let directory = stagingDirectory
            let limit = maxPdfBytes
            let result: StageResult = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                    guard let url else { return continuation.resume(returning: .failed(.unknown)) }
                    continuation.resume(returning: Self.stage(url, maxBytes: limit, in: directory))
                }
            }
            switch result {
            case .staged(let url): staged.append(url)
            case .failed(let error): firstError = firstError ?? error
            }
        }
        if !staged.isEmpty { return .pdfs(staged) }
        return .rejectedPdf(firstError ?? .unknown)
    }

    /// Checks size and header of `source`, then copies it to its own directory under `directory`.
    nonisolated static func stage(_ source: URL, maxBytes: Int64, in directory: URL) -> StageResult {
        let manager = FileManager.default
        guard let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return .failed(.unknown)
        }
        if Int64(size) > maxBytes { return .failed(.tooLarge) }
        guard let handle = try? FileHandle(forReadingFrom: source) else { return .failed(.unknown) }
        let header = (try? handle.read(upToCount: 5)) ?? nil
        try? handle.close()
        guard header == Data("%PDF-".utf8) else { return .failed(.notPdf) }
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appending(path: source.lastPathComponent)
            try manager.copyItem(at: source, to: destination)
            return .staged(destination)
        } catch {
            return .failed(.storageFull)
        }
    }

    /// Outcome of staging one PDF (`PdfUploadError` is not an `Error`, so no `Result`).
    enum StageResult: Sendable {
        case staged(URL)
        case failed(PdfUploadError)
    }
}
