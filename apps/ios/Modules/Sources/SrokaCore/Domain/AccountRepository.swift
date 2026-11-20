import Dependencies

/// Account-level server operations (api.md §12). Android: AccountRepository.kt.
public protocol AccountRepository: Sendable {
    /// Deletes the account on the server, then signs out and wipes local data.
    func deleteAccount() async -> DeleteAccountResult

    /// Which client types this account has used (`GET /v1/me` `clients`). nil when the request
    /// failed (offline, signed out, server error): callers stay silent.
    func connectedClients() async -> ConnectedClients?
}

/// Client types that have signed in for this account. `ios` is read when the server reports it.
public struct ConnectedClients: Sendable, Hashable {
    public var extensionClient: Bool
    public var android: Bool
    public var ios: Bool

    public init(extensionClient: Bool = false, android: Bool = false, ios: Bool = false) {
        self.extensionClient = extensionClient
        self.android = android
        self.ios = ios
    }
}

public enum DeleteAccountResult: Sendable, Hashable {
    case deleted
    case failed(RemoteFailure)
}

private struct UnimplementedAccountRepository: AccountRepository {
    private func fail(_ method: String) { reportUnimplemented("AccountRepository.\(method)", key: "accountRepository") }

    func deleteAccount() async -> DeleteAccountResult {
        fail("deleteAccount")
        return .failed(.server)
    }
    func connectedClients() async -> ConnectedClients? {
        fail("connectedClients")
        return nil
    }
}

private enum AccountRepositoryKey: TestDependencyKey {
    static let testValue: any AccountRepository = UnimplementedAccountRepository()
}

extension DependencyValues {
    public var accountRepository: any AccountRepository {
        get { self[AccountRepositoryKey.self] }
        set { self[AccountRepositoryKey.self] = newValue }
    }
}
