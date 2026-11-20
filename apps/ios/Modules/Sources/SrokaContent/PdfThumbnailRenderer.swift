import Foundation
import PDFKit
import SrokaCore
import UIKit

/// First-page preview of an uploaded PDF (Android `PdfThumbnailRenderer.kt`): JPEG, about 480 px wide, at most
/// `Limits.maxThumbnailBytes`. Best effort: nil for an unreadable or encrypted document.
public enum PdfThumbnailRenderer {
    public static let width: CGFloat = 480
    public static let contentType = "image/jpeg"

    public static func render(_ file: URL, maxBytes: Int = Limits.maxThumbnailBytes) -> Data? {
        guard let document = PDFDocument(url: file), !document.isLocked, let page = document.page(at: 0) else {
            return nil
        }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Cap very tall pages so the JPEG stays small.
        let height = min(width * bounds.height / bounds.width, width * 4)
        let image = page.thumbnail(of: CGSize(width: width, height: height), for: .mediaBox)
        for quality in [0.8, 0.65, 0.5, 0.35, 0.2] {
            if let data = image.jpegData(compressionQuality: quality), !data.isEmpty, data.count <= maxBytes {
                return data
            }
        }
        return nil
    }
}
