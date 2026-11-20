import Foundation
import SrokaCore

/// Every way an API call can fail, in one model. Calls throw this (or `CancellationError`, which is never wrapped).
/// Messages from the server are kept for diagnostics only: never show them or log them (they may echo input).
public enum ApiError: Error, Sendable, Equatable {
    /// No connection, timeout, TLS or other transport problem.
    case transport(URLError.Code)
    /// The server answered with a non-2xx status.
    case http(status: Int, code: String?, message: String?, retryAfter: TimeInterval?)
    /// A 2xx answer that could not be decoded, or lacks a required header (`set-auth-token`).
    case malformedResponse
    /// The request was refused before sending (oversized push, bad URL, unreadable file).
    case invalidRequest

    public var status: Int? {
        if case .http(let status, _, _, _) = self { return status }
        return nil
    }

    /// `error` (`/v1`) or `code` (Better Auth), e.g. `resync_required`, `not_parsed`, `INVALID_OTP`.
    public var code: String? {
        if case .http(_, let code, _, _) = self { return code }
        return nil
    }

    /// Seconds from `Retry-After` (`/v1`) or `X-Retry-After` (Better Auth).
    public var retryAfter: TimeInterval? {
        if case .http(_, _, _, let retryAfter) = self { return retryAfter }
        return nil
    }

    public var isResyncRequired: Bool { status == 410 && code == "resync_required" }
    public var isNotParsed: Bool { status == 409 && code == "not_parsed" }
    public var isUnauthorized: Bool { status == 401 }

    /// The coarse failure the domain layer shows.
    public var remoteFailure: RemoteFailure {
        switch self {
        case .transport: .network
        case .http(let status, _, _, _):
            switch status {
            case 401: .unauthorized
            case 429: .rateLimited
            default: .server
            }
        case .malformedResponse, .invalidRequest: .server
        }
    }

    /// Mapping for `POST /v1/items/pdf` answers.
    public var pdfUploadError: PdfUploadError {
        switch self {
        case .transport: .network
        case .http(let status, let code, _, _):
            switch (status, code) {
            case (401, _): .auth
            case (413, _): .tooLarge
            case (415, _): .notPdf
            case (409, "storage_full"): .storageFull
            default: .unknown
            }
        case .malformedResponse, .invalidRequest: .unknown
        }
    }
}

/// Both server error shapes: `/v1` `{error, message?}` and Better Auth `{code, message}`.
struct ErrorBody: Decodable {
    var error: String?
    var code: String?
    var message: String?

    private enum CodingKeys: String, CodingKey { case error, code, message }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        code = try? container.decodeIfPresent(String.self, forKey: .code)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
    }
}

enum ErrorParsing {
    /// `Retry-After` wins; Better Auth rate limits use `X-Retry-After`. Only whole/decimal seconds are understood.
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        for name in ["Retry-After", "X-Retry-After"] {
            if let raw = response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespaces),
                let seconds = Double(raw), seconds >= 0, seconds.isFinite
            {
                return seconds
            }
        }
        return nil
    }

    static func error(from response: HTTPURLResponse, body: Data) -> ApiError {
        let parsed = try? JSONDecoder().decode(ErrorBody.self, from: body)
        return .http(
            status: response.statusCode,
            code: parsed?.code ?? parsed?.error,
            message: parsed?.message,
            retryAfter: retryAfter(from: response)
        )
    }
}
