import Foundation
import SrokaCore
import SrokaNetwork

/// `LivePdfUploader(boundAPI:)`: the API for one upload, pinned to one endpoint snapshot that belongs to the
/// account that queued it.
///
/// The endpoint's token must be the stored session's token, so the snapshot and the owner check describe the same
/// account (tokens are unique per sign-in). A switch after this returns cannot change what the upload and its
/// thumbnail send. Nil (signed out, another account, token rotating): the upload waits for the next resume.
public enum OwnerBoundAPI {
    public static func make(
        api: HTTPSrokaAPI,
        provider: any ApiSessionProvider,
        current: @escaping @Sendable () -> StoredSession?
    ) -> @Sendable (_ owner: String?) async -> (any SrokaAPI)? {
        { owner in
            let endpoint = await provider.endpoint()
            guard let token = endpoint.token, let session = current(), session.token == token,
                owner == nil || owner == session.ownerKey
            else { return nil }
            return api.pinned(to: endpoint)
        }
    }
}
