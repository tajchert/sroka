import Foundation

/// Builds a `multipart/form-data` body in a temporary file, so imports (up to 20 MiB) never sit in memory.
struct MultipartBody {
    let boundary: String
    let fileURL: URL

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// One text field `format` first, then the file part named `file`. The caller deletes `fileURL` when done.
    static func make(
        fields: [(name: String, value: String)],
        fileField: String,
        fileName: String,
        mimeType: String,
        source: URL
    ) throws -> MultipartBody {
        let boundary = "sroka-\(UUID().uuidString)"
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sroka-multipart-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw ApiError.invalidRequest }
        do {
            let out = try FileHandle(forWritingTo: target)
            defer { try? out.close() }
            for field in fields {
                try out.write(
                    contentsOf: Data(
                        "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quote(field.name))\"\r\n\r\n\(field.value)\r\n"
                            .utf8))
            }
            try out.write(
                contentsOf: Data(
                    ("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quote(fileField))\"; "
                        + "filename=\"\(quote(fileName))\"\r\nContent-Type: \(headerSafe(mimeType))\r\n\r\n").utf8))
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw ApiError.invalidRequest
        }
        return MultipartBody(boundary: boundary, fileURL: target)
    }

    /// Quoted-string value: no CR/LF, `"` and `\` escaped (RFC 7578 §4.2 style, as browsers do with `%22`).
    private static func quote(_ value: String) -> String {
        headerSafe(value).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "%22")
    }

    private static func headerSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }
}
