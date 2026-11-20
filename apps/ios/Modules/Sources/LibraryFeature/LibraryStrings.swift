import Foundation
import SrokaCore

/// Text produced by the view model (toasts), the same words as Android. View text uses
/// `Text("…", bundle: #bundle)` directly.
enum LibraryStrings {
    static let undo = LocalizedStringResource("Undo", bundle: #bundle)
    static let open = LocalizedStringResource("Open", bundle: #bundle)

    static func archived(offline: Bool) -> LocalizedStringResource {
        offline
            ? LocalizedStringResource("Archived. Syncs when you’re online.", bundle: #bundle)
            : LocalizedStringResource("Archived", bundle: #bundle)
    }

    static func unarchived(offline: Bool) -> LocalizedStringResource {
        offline
            ? LocalizedStringResource("Moved to My List. Syncs when you’re online.", bundle: #bundle)
            : LocalizedStringResource("Moved to My List", bundle: #bundle)
    }

    static let addedToFavorites = LocalizedStringResource("Added to favorites", bundle: #bundle)
    static let removedFromFavorites = LocalizedStringResource("Removed from favorites", bundle: #bundle)
    static let articleDeleted = LocalizedStringResource("Article deleted", bundle: #bundle)
    static let refreshing = LocalizedStringResource("Refreshing article", bundle: #bundle)
    static let saved = LocalizedStringResource("Saved", bundle: #bundle)
    static let alreadySavedMoved = LocalizedStringResource("Already saved. Moved to My List.", bundle: #bundle)
    static let noLinkFound = LocalizedStringResource("Couldn’t find a link to save", bundle: #bundle)
    static let savedToSroka = LocalizedStringResource("Saved to Sroka", bundle: #bundle)
    static let alreadyInSroka = LocalizedStringResource("Already in Sroka", bundle: #bundle)

    static func savedLinks(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("Saved \(count) links", bundle: #bundle)
    }

    static let uploadingPdf = LocalizedStringResource("Uploading PDF", bundle: #bundle)

    static func uploadingPdfs(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("Uploading \(count) PDFs", bundle: #bundle)
    }

    static let pdfAdded = LocalizedStringResource("PDF added to Sroka", bundle: #bundle)

    static func pdfFailed(_ error: PdfUploadError) -> LocalizedStringResource {
        let reason = uploadError(error)
        return LocalizedStringResource("Couldn’t add PDF. \(String(localized: reason))", bundle: #bundle)
    }

    static func uploadError(_ error: PdfUploadError) -> LocalizedStringResource {
        switch error {
        case .tooLarge: LocalizedStringResource("Too large. PDFs can be up to 50 MB.", bundle: #bundle)
        case .notPdf: LocalizedStringResource("Not a PDF file.", bundle: #bundle)
        case .storageFull: LocalizedStringResource("Storage is full.", bundle: #bundle)
        case .network: LocalizedStringResource("No connection. Check your network.", bundle: #bundle)
        case .unknown: LocalizedStringResource("Something went wrong. Try again later.", bundle: #bundle)
        case .auth: LocalizedStringResource("Sign in again to upload.", bundle: #bundle)
        }
    }

    static let upToDate = LocalizedStringResource("Library is up to date", bundle: #bundle)

    static func readyOffline(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) articles ready offline", bundle: #bundle)
    }

    static func fetchFailed(_ kind: SyncErrorKind) -> LocalizedStringResource {
        switch kind {
        case .network: LocalizedStringResource("Couldn’t fetch: no connection", bundle: #bundle)
        case .server: LocalizedStringResource("Couldn’t fetch: server problem", bundle: #bundle)
        case .auth: LocalizedStringResource("Couldn’t fetch: sign in again", bundle: #bundle)
        case .storage: LocalizedStringResource("Couldn’t download: device storage is full", bundle: #bundle)
        }
    }
}
