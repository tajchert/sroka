import Foundation

// STUB from the foundation stream: only the signature models need (`displayDomain`).
// Stream A owns this file and replaces it with the full hand-written WHATWG port of
// `packages/shared/src/url.ts` (normalize, isHttpUrl, hostOf, extractFirstUrl) and its test vectors.
public enum UrlNormalizer {
    /// Lower-cased (punycode) host of `url`, or nil if it is not an http(s) URL.
    public static func hostOf(_ url: String) -> String? {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        return host.lowercased()
    }
}
