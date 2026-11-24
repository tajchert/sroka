import CryptoKit
import Foundation
import SrokaCore
import ZIPFoundation

/// Safely unpacks an article package (`package.zip`: `manifest.json`, `article.html`, `img/…`) into
/// `articles/{itemId}/` (DECISIONS A9; Android `PackageInstaller.kt`). A pure function over a zip file and a
/// destination, so a background `URLSession` + `BGProcessingTask` can run it on whatever arrived.
///
/// - Every entry name must pass `safeRelativePath` (no absolute paths, `.`/`..` segments, `\`, `:`, NUL, or
///   names over 512 characters); case-insensitive duplicates, symlinks, and a file that is also used as a
///   directory are rejected before anything is written.
/// - At most `maxEntries` entries and `maxTotalBytes` unpacked bytes, counted while writing (headers are not
///   trusted).
/// - `manifest.json` must list `article.html`; every listed file's SHA-256 must match.
/// - Unpacks into `articles/{itemId}.tmp`, then swaps it in by rename, so any failure leaves the previous
///   package untouched.
public struct PackageInstaller: Sendable {
    public static let maxTotalBytes: Int64 = 50 * 1024 * 1024
    public static let maxEntries = 200
    public static let maxNameLength = 512
    static let manifestFile = "manifest.json"

    public enum Result: Sendable, Equatable {
        case installed(bytes: Int64)
        /// The package is broken or hostile; `reason` is a short code (never shown to users).
        case invalid(reason: String)
        /// Local I/O failure (typically a full disk): transient, not the package's fault.
        case ioError(domain: String, code: Int)
    }

    let maxTotalBytes: Int64
    let maxEntries: Int
    /// File moves; tests inject a failing one to simulate an interrupted swap.
    let move: @Sendable (URL, URL) throws -> Void

    public init(
        maxTotalBytes: Int64 = PackageInstaller.maxTotalBytes,
        maxEntries: Int = PackageInstaller.maxEntries
    ) {
        self.init(maxTotalBytes: maxTotalBytes, maxEntries: maxEntries) {
            try FileManager.default.moveItem(at: $0, to: $1)
        }
    }

    init(maxTotalBytes: Int64, maxEntries: Int, move: @escaping @Sendable (URL, URL) throws -> Void) {
        self.maxTotalBytes = maxTotalBytes
        self.maxEntries = maxEntries
        self.move = move
    }

    /// Installs `zip` as the package of `itemId` under `articlesDirectory`. Never throws.
    public func install(zip: URL, articlesDirectory: URL, itemId: String) -> Result {
        guard isValidItemId(itemId) else { return .invalid(reason: "unsafe_id") }
        let fileManager = FileManager.default
        let tmp = articlesDirectory.appending(path: itemId + ContentPaths.tmpSuffix, directoryHint: .isDirectory)
        let target = articlesDirectory.appending(path: itemId, directoryHint: .isDirectory)
        let old = articlesDirectory.appending(path: itemId + ContentPaths.oldSuffix, directoryHint: .isDirectory)
        try? fileManager.removeItem(at: tmp)
        do {
            try fileManager.createDirectory(at: tmp, withIntermediateDirectories: true)
            try unzip(zip, into: tmp)
            try verify(tmp)
            try swap(tmp: tmp, target: target, old: old)
            return .installed(bytes: ContentPaths.size(of: target))
        } catch let error as InvalidPackage {
            try? fileManager.removeItem(at: tmp)
            return .invalid(reason: error.reason)
        } catch {
            try? fileManager.removeItem(at: tmp)
            let nsError = error as NSError
            return .ioError(domain: nsError.domain, code: nsError.code)
        }
    }

    // MARK: Steps

    private func unzip(_ zip: URL, into dir: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: zip, accessMode: .read)
        } catch {
            throw InvalidPackage("bad_zip")
        }
        // Pass 1: names only. Nothing is written until the whole listing is acceptable.
        var entries: [(Entry, String)] = []
        var seen = Set<String>()
        var files = Set<String>()
        var directories = Set<String>()
        for entry in archive {
            if entries.count >= maxEntries { throw InvalidPackage("too_many_entries") }
            guard let name = Self.safeRelativePath(entry.path) else { throw InvalidPackage("unsafe_path") }
            switch entry.type {
            case .symlink: throw InvalidPackage("unsafe_path")
            case .directory: directories.insert(name.lowercased())
            case .file: files.insert(name.lowercased())
            }
            guard seen.insert(name.lowercased()).inserted else { throw InvalidPackage("duplicate_entry") }
            var parent = name.lowercased()
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                directories.insert(parent)
            }
            entries.append((entry, name))
        }
        if entries.isEmpty { throw InvalidPackage("empty") }
        if !files.isDisjoint(with: directories) { throw InvalidPackage("path_conflict") }

        // Pass 2: write, counting real bytes.
        // Compared by path components, never through `standardizedFileURL`: under `/private/var` (every container on a
        // device) it drops "/private" for a path that exists and keeps it for one that does not yet, so the existing
        // root and a file about to be written never shared a prefix and every package was refused as `unsafe_path`.
        // `name` is already free of "..", "." and absolute segments (`safeRelativePath`), so this is a second check.
        let root = dir.pathComponents
        var total: Int64 = 0
        for (entry, name) in entries {
            let out = dir.appending(path: name, directoryHint: entry.type == .directory ? .isDirectory : .notDirectory)
            let components = out.pathComponents
            guard components.count > root.count, Array(components.prefix(root.count)) == root,
                !components.contains("..")
            else { throw InvalidPackage("unsafe_path") }
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(
                at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: out.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            do {
                _ = try archive.extract(entry, skipCRC32: false) { chunk in
                    total += Int64(chunk.count)
                    if total > maxTotalBytes { throw InvalidPackage("too_large") }
                    do {
                        try handle.write(contentsOf: chunk)
                    } catch {
                        throw WriteFailure()
                    }
                }
            } catch let error as InvalidPackage {
                throw error
            } catch is WriteFailure {
                throw CocoaError(.fileWriteOutOfSpace)
            } catch {
                // Anything the archive itself raised (CRC, truncated data, bad headers) is the package's fault.
                throw InvalidPackage("bad_zip")
            }
        }
    }

    private func verify(_ dir: URL) throws {
        let manifestURL = dir.appending(path: Self.manifestFile, directoryHint: .notDirectory)
        guard ContentPaths.isFile(manifestURL) else { throw InvalidPackage("no_manifest") }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch is DecodingError {
            throw InvalidPackage("bad_manifest")
        }
        guard manifest.files.contains(where: { $0.path == ContentPaths.articleFile }) else {
            throw InvalidPackage("no_article")
        }
        // Each file is hashed once: a manifest repeating a path must not multiply the work.
        if manifest.files.count > maxEntries { throw InvalidPackage("bad_manifest") }
        var listed = Set<String>()
        for file in manifest.files {
            guard let path = Self.safeRelativePath(file.path) else { throw InvalidPackage("unsafe_path") }
            guard listed.insert(path.lowercased()).inserted else { throw InvalidPackage("bad_manifest") }
            let url = dir.appending(path: path, directoryHint: .notDirectory)
            guard ContentPaths.isFile(url) else { throw InvalidPackage("missing_file") }
            guard try Self.sha256Hex(url).caseInsensitiveCompare(file.sha256) == .orderedSame else {
                throw InvalidPackage("sha256_mismatch")
            }
        }
    }

    /// `target` → `old`, `tmp` → `target`, delete `old`. If the second move fails the old package is moved back.
    private func swap(tmp: URL, target: URL, old: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: old)
        let hadTarget = fileManager.fileExists(atPath: target.path)
        if hadTarget { try move(target, old) }
        do {
            try move(tmp, target)
        } catch {
            if hadTarget { try? move(old, target) }
            throw error
        }
        try? fileManager.removeItem(at: old)
    }

    // MARK: Helpers

    /// A relative path with `/` separators, or nil if it could escape the target directory.
    public static func safeRelativePath(_ name: String) -> String? {
        if name.isEmpty || name.utf16.count > maxNameLength { return nil }
        if name.hasPrefix("/") || name.contains("\\") || name.contains(":") || name.contains("\u{0}") { return nil }
        var trimmed = Substring(name)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        if segments.isEmpty || segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return nil }
        return segments.joined(separator: "/")
    }

    public static func sha256Hex(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Manifest: Decodable {
        var files: [ManifestFile]

        private enum CodingKeys: String, CodingKey { case files }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            files = try container.decodeIfPresent([ManifestFile].self, forKey: .files) ?? []
        }
    }

    private struct ManifestFile: Decodable {
        var path: String
        var sha256: String
    }

    struct InvalidPackage: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    private struct WriteFailure: Error {}
}
