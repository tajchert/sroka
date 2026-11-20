import Foundation
import SrokaCore

/// The server calls the app makes (api.md; the exact set Android uses plus `config`). All list, edit and tag changes
/// go through sync ops, not REST. Calls throw `ApiError` or `CancellationError` and nothing else.
public protocol SrokaAPI: Sendable {
    // Auth (Better Auth; no Origin header, ever)
    /// `POST /api/auth/email-otp/send-verification-otp`. The same answer whether or not the account exists.
    func sendOtp(email: String) async throws
    /// `POST /api/auth/sign-in/email-otp`; the token comes from the `set-auth-token` response header.
    func signIn(email: String, otp: String) async throws -> SignInResult
    /// `POST /api/auth/sign-out`, best effort with a 5 s timeout.
    func signOut() async throws

    // Sync
    /// `POST /v1/sync/push` with canonical op payloads (`WireOp.payload`), up to 500 of them, sent byte for byte.
    func push(payloads: [String]) async throws -> PushResponseDto
    /// `GET /v1/sync/pull`. A 410 `resync_required` throws an `ApiError` whose `isResyncRequired` is true.
    func pull(cursor: Int64, limit: Int, full: Bool) async throws -> PullResponseDto

    // Items
    /// `GET /v1/items/{id}` (the reader's Refresh polling).
    func item(id: String) async throws -> ItemDto
    /// `GET /v1/items/{id}/content`. 409 `not_parsed` throws an `ApiError` whose `isNotParsed` is true.
    func contentUrls(itemId: String) async throws -> ContentUrlsDto
    /// `POST /v1/items/pdf`: raw bytes from `file`, `Content-Length` set, query `name`, `source`, `tag` (repeated).
    func uploadPdf(
        file: URL, fileName: String, tags: [String], source: ItemSource, onProgress: ByteProgress?
    ) async throws -> PdfUploadResponseDto
    /// `PUT /v1/items/{id}/thumbnail` with `image/webp` or `image/jpeg`, at most `Limits.maxThumbnailBytes`.
    func uploadThumbnail(itemId: String, data: Data, contentType: String) async throws -> ItemDto

    // Account
    func me() async throws -> MeDto
    /// `DELETE /v1/account` with `{"confirm":"DELETE"}`.
    func deleteAccount() async throws

    // Push
    /// `PUT /v1/push-token`: registers or refreshes this device's push token (204).
    func putPushToken(_ body: PushTokenRequestDto) async throws
    /// `DELETE /v1/push-token`: removes this device's push token (204, also when none was stored).
    func deletePushToken() async throws

    // Import / export
    /// `POST /v1/imports` (multipart `file` + `format`, file at most `Limits.maxImportBytes`).
    func createImport(source: URL, fileName: String, mimeType: String, format: ImportFormat) async throws -> JobDto
    func importJob(id: String) async throws -> JobDto
    /// `GET /v1/exports?format=` streamed to `destination`; the name comes from `Content-Disposition`.
    func export(format: ExportFormat, to destination: URL) async throws -> ExportFile

    // Public / content host
    /// `GET /v1/config` (no auth needed).
    func config() async throws -> ConfigDto
    /// Downloads a signed content URL (content host) to `destination`. Sends no auth header and no device header.
    func download(from url: URL, to destination: URL, onProgress: ByteProgress?) async throws
}

extension SrokaAPI {
    /// Pushes typed ops; payloads are the canonical JSON of each op.
    public func push(ops: [WireOp]) async throws -> PushResponseDto {
        try await push(payloads: ops.map(\.payload))
    }
}
