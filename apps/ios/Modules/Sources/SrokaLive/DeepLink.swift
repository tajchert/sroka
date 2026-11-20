import Foundation
import Observation
import SrokaCore

/// A link the app can open: `<scheme>://item/{id}` (`sroka` in Prod, `sroka-dev` in Dev).
public enum DeepLink: Sendable, Hashable {
    case item(id: String)

    /// Parses `url` for this build's `scheme`. Anything else (another scheme or host, extra path segments, an id that
    /// fails `isValidItemId`, credentials or a port) is nil. A query or fragment is ignored.
    public init?(url: URL, scheme: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let urlScheme = components.scheme, urlScheme.caseInsensitiveCompare(scheme) == .orderedSame,
            let host = components.percentEncodedHost, host.caseInsensitiveCompare("item") == .orderedSame,
            components.user == nil, components.password == nil, components.port == nil
        else { return nil }
        // The raw path: a percent-encoded id contains "%", which `isValidItemId` rejects.
        var path = components.percentEncodedPath
        guard path.hasPrefix("/") else { return nil }
        path.removeFirst()
        if path.hasSuffix("/") { path.removeLast() }
        guard isValidItemId(path) else { return nil }
        self = .item(id: path)
    }
}

/// Deep links waiting for the root navigation to open them. The root navigation reads `pendingItemId` and calls
/// `consumePendingItem()` once it has shown the item (after sign-in when the app is signed out).
@Observable @MainActor
public final class DeepLinkInbox {
    public private(set) var pendingItemId: String?

    @ObservationIgnored private let scheme: String

    public init(scheme: String) {
        self.scheme = scheme
    }

    /// Accepts a URL from `onOpenURL`. Returns false (and changes nothing) when it is not one of the app's links.
    @discardableResult public func handle(_ url: URL) -> Bool {
        guard let link = DeepLink(url: url, scheme: scheme) else {
            liveLog.notice("Ignored a link the app does not handle")
            return false
        }
        switch link {
        case .item(let id): pendingItemId = id
        }
        return true
    }

    /// Returns the pending item id and clears it.
    public func consumePendingItem() -> String? {
        defer { pendingItemId = nil }
        return pendingItemId
    }
}
