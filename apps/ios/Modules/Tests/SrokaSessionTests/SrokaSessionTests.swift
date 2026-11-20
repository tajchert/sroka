import Clocks
import Foundation
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import Synchronization
import Testing

@testable import SrokaSession

struct SessionStoreTests {
    @Test func `Session moves from signed out to signed in to expired to signed out`() async throws {
        let h = try Harness()
        var states = h.auth.session.makeAsyncIterator()
        #expect(await states.next() == .signedOut)

        #expect(await h.signIn("a@b.co") == .success)
        #expect(await states.next() == .signedIn(email: "a@b.co"))

        h.auth.markSessionExpired()
        #expect(await states.next() == .expired(email: "a@b.co"))
        // Expired keeps the token for the extension and keeps the email for "Sign in again".
        #expect(h.sessionStore.current?.expired == true)

        h.api.configure { $0.signOut = {} }
        await h.auth.signOut()
        #expect(await states.next() == .signedOut)
    }

    @Test func `Expired session signs in again to signed in`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        h.auth.markSessionExpired()
        #expect(await h.signIn("a@b.co", token: "fresh") == .success)
        #expect(
            h.sessionStore.current
                == StoredSession(token: "fresh", email: "a@b.co", expired: false, server: Harness.defaultServer))
    }

    @Test func `Marking expired while signed out does nothing`() async throws {
        let h = try Harness()
        h.auth.markSessionExpired()
        #expect(h.sessionStore.current == nil)
        #expect(h.keychain.snapshot[SessionStore.sessionKey] == nil)
    }

    @Test func `A stale 401 in another process does not write a signed-out token back`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co", token: "old")
        let extensionStore = SessionStore(store: h.keychain)
        h.sessionStore.clear()  // The app signs out.
        extensionStore.markExpired()  // The extension's request with the old token gets a 401.
        #expect(extensionStore.current == nil)
        h.sessionStore.reload()
        #expect(h.sessionStore.current == nil)
    }

    @Test func `Token is stored verbatim and survives a new store instance`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co", token: "abc.def==")
        let reopened = SessionStore(store: h.keychain)
        #expect(reopened.token == "abc.def==")
        #expect(await h.provider.token() == "abc.def==")
    }

    @Test func `An unreadable keychain reads as signed out`() async throws {
        let keychain = InMemorySecureStore([SessionStore.sessionKey: "not json"])
        #expect(SessionStore(store: keychain).current == nil)
        keychain.setFailure(SecureStoreError(status: -25308))
        #expect(SessionStore(store: keychain).current == nil)
    }

    @Test func `Device id is ios_ plus a uuidv7, generated once and kept across sign out`() async throws {
        let h = try Harness()
        let id = h.sessionStore.deviceId()
        #expect(id.hasPrefix("ios_"))
        #expect(UUIDv7.isUuid(String(id.dropFirst(4))))
        #expect(h.sessionStore.deviceId() == id)

        _ = await h.signIn("a@b.co")
        h.api.configure { $0.signOut = {} }
        await h.auth.signOut()
        #expect(await h.provider.deviceId() == id)
        #expect(SessionStore(store: h.keychain).deviceId() == id)
    }
}

struct SignInTests {
    @Test func `Email is trimmed and validated before any request`() async throws {
        let h = try Harness()
        h.api.configure { $0.sendOtp = { email in #expect(email == "a@b.co") } }
        #expect(await h.auth.sendCode(email: "  a@b.co \n") == .success)
        #expect(await h.auth.sendCode(email: "not-an-email") == .failure(.invalidEmail))
        #expect(await h.auth.sendCode(email: "a b@c.de") == .failure(.invalidEmail))
        let long = String(repeating: "a", count: 250) + "@b.co"
        #expect(await h.auth.sendCode(email: long) == .failure(.invalidEmail))
        #expect(h.api.recorded == ["sendOtp"])
    }

    @Test func `Whitespace is stripped from the code`() async throws {
        let h = try Harness()
        h.api.configure { $0.signIn = { _, _ in SignInResult(token: "t", userEmail: "a@b.co") } }
        #expect(await h.auth.signIn(email: "a@b.co", code: " 12 34\t56 ") == .success)
        #expect(h.api.recorded == ["signIn:123456"])
        #expect(await h.auth.signIn(email: "a@b.co", code: "   ") == .failure(.invalidCode))
    }

    @Test(arguments: [
        (httpError(400, code: "INVALID_OTP"), AuthError.invalidCode),
        (httpError(400, code: "OTP_EXPIRED"), .codeExpired),
        (httpError(403, code: "TOO_MANY_ATTEMPTS"), .tooManyAttempts),
        (httpError(400, code: "INVALID_EMAIL"), .invalidEmail),
        (httpError(429, retryAfter: 30), .rateLimited(retryAfterSeconds: 30)),
        (httpError(429), .rateLimited(retryAfterSeconds: nil)),
        (httpError(429, retryAfter: 1e30), .rateLimited(retryAfterSeconds: nil)),
        (httpError(500), .server),
        (ApiError.transport(.notConnectedToInternet), .network),
        (ApiError.malformedResponse, .server),
    ])
    func `Server errors map to auth errors`(error: ApiError, expected: AuthError) async throws {
        let h = try Harness()
        h.api.configure { $0.signIn = { _, _ in throw error } }
        #expect(await h.auth.signIn(email: "a@b.co", code: "1") == .failure(expected))
        #expect(h.sessionStore.current == nil)
    }

    @Test func `Sign in stores the account marker and requests a sync`() async throws {
        let h = try Harness()
        #expect(await h.signIn("a@b.co") == .success)
        #expect(h.preferences.accountEmail == "a@b.co")
        #expect(h.preferences.accountServer == Harness.defaultServer)
        #expect(h.syncRequests.withLock { $0 } == 1)
    }

    @Test func `Same account on the same server keeps local data`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        try await h.insertItem()
        h.auth.markSessionExpired()
        #expect(await h.signIn("A@B.co") == .success)
        #expect(try await h.itemCount() == 1)
    }

    @Test func `Another email wipes local data first`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        try await h.insertItem()
        try await h.insertPendingOp()
        h.auth.markSessionExpired()
        #expect(await h.signIn("other@b.co") == .success)
        #expect(try await h.itemCount() == 0)
        #expect(try await h.pendingOpCount() == 0)
        #expect(h.preferences.accountEmail == "other@b.co")
    }

    @Test func `Same email on another server wipes local data first`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        try await h.insertItem()
        // Simulates data synced from another server (e.g. restored marker).
        h.preferences.accountServer = "https://old.example.com"
        #expect(await h.signIn("a@b.co") == .success)
        #expect(try await h.itemCount() == 0)
        #expect(h.preferences.accountServer == Harness.defaultServer)
    }

    @Test func `Data with no recorded owner is wiped on sign in`() async throws {
        let h = try Harness()
        try await h.insertItem()
        #expect(await h.signIn("a@b.co") == .success)
        #expect(try await h.itemCount() == 0)
    }

    @Test func `Pending ops with no recorded owner are wiped on sign in`() async throws {
        let h = try Harness()
        try await h.insertPendingOp()
        _ = await h.signIn("a@b.co")
        #expect(try await h.pendingOpCount() == 0)
    }

    @Test func `Unknown server marker with the same email keeps data`() async throws {
        let h = try Harness()
        h.preferences.accountEmail = "a@b.co"
        try await h.insertItem()
        _ = await h.signIn("a@b.co")
        #expect(try await h.itemCount() == 1)
    }

    @Test func `A token from the old server is dropped when the server changes during sign in`() async throws {
        let h = try Harness()
        let preferences = h.preferences
        h.api.configure {
            $0.signIn = { _, _ in
                preferences.setServerUrl("https://other.example.com")
                return SignInResult(token: "old-server", userEmail: "a@b.co")
            }
        }
        #expect(await h.auth.signIn(email: "a@b.co", code: "1") == .failure(.server))
        #expect(h.sessionStore.current == nil)
        #expect(h.preferences.accountServer == nil)
    }

    @Test func `A sign in in flight across a switch away and back is dropped`() async throws {
        let h = try Harness()
        let settings = h.settings
        h.api.configure {
            $0.signIn = { _, _ in
                _ = await settings.setServerUrl("https://other.example.com")
                _ = await settings.setServerUrl(nil)
                return SignInResult(token: "stale", userEmail: "a@b.co")
            }
        }
        #expect(await h.auth.signIn(email: "a@b.co", code: "1") == .failure(.server))
        #expect(h.sessionStore.current == nil)
    }

    @Test func `A sign in still in flight across a sign out does not restore the session`() async throws {
        let h = try Harness()
        let auth = h.auth
        h.api.configure {
            $0.signIn = { _, _ in
                await auth.clearLocal()
                return SignInResult(token: "late", userEmail: "a@b.co")
            }
        }
        #expect(await h.auth.signIn(email: "a@b.co", code: "1") == .failure(.server))
        #expect(h.sessionStore.current == nil)
    }

    @Test func `Signing in as another account fails when the old rows cannot be removed`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        try await h.insertItem()
        struct Boom: Error {}
        let wiper = LocalDataWiper(
            database: h.database, cancelAllWork: {}, clearTables: { throw Boom() }, deleteFiles: {},
            transferDirectories: [], sessionStore: h.sessionStore, preferences: h.preferences, importJobs: h.jobs)
        let database = h.database
        let auth = LiveAuthRepository(
            api: h.api, sessionStore: h.sessionStore, preferences: h.preferences, provider: h.provider, wiper: wiper,
            hasLocalData: { await LiveAuthRepository.hasAccountData(in: database) }, requestSync: {}, clock: h.clock)
        h.api.configure { $0.signIn = { _, _ in SignInResult(token: "t2", userEmail: "other@b.co") } }
        #expect(await auth.signIn(email: "other@b.co", code: "1") == .failure(.server))
        #expect(h.sessionStore.current == nil)
        #expect(h.preferences.accountEmail == nil)
    }

    @Test func `A 401 elsewhere keeps the library`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        try await h.insertItem()
        h.auth.markSessionExpired()
        #expect(try await h.itemCount() == 1)
        #expect(h.preferences.accountEmail == "a@b.co")
    }
}

struct SignOutTests {
    @Test func `Sign out calls the server with the token, then wipes`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co", token: "tok")
        try await h.insertItem()
        let provider = h.provider
        h.api.configure {
            $0.signOut = { #expect(await provider.token() == "tok") }
        }
        await h.auth.signOut()
        #expect(h.api.recorded.contains("signOut"))
        #expect(try await h.itemCount() == 0)
        #expect(h.sessionStore.current == nil)
        #expect(h.preferences.accountEmail == nil)
        #expect(h.preferences.accountServer == nil)
    }

    @Test func `Sign out wipes even when the server call fails`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        try await h.insertItem()
        h.api.configure { $0.signOut = { throw ApiError.transport(.notConnectedToInternet) } }
        await h.auth.signOut()
        #expect(try await h.itemCount() == 0)
        #expect(h.sessionStore.current == nil)
    }

    @Test func `Sign out wipes after 5 seconds when the server hangs`() async throws {
        let clock = ImmediateClock()
        let start = clock.now
        let h = try Harness(clock: clock)
        _ = await h.signIn("a@b.co")
        try await h.insertItem()
        h.api.configure {
            $0.signOut = {
                // Never answers and ignores cancellation: the timeout must not depend on it.
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            }
        }
        await h.auth.signOut()
        // The only wait was the 5 s timeout.
        #expect(start.duration(to: clock.now) == .seconds(5))
        #expect(try await h.itemCount() == 0)
        #expect(h.sessionStore.current == nil)
    }

    @Test func `Wipe keeps the device id and preferences`() async throws {
        let h = try Harness()
        let deviceId = h.sessionStore.deviceId()
        await h.settings.setThemeMode(.dark)
        _ = await h.signIn("a@b.co")
        h.api.configure { $0.signOut = {} }
        await h.auth.signOut()
        #expect(h.sessionStore.deviceId() == deviceId)
        #expect(h.preferences.preferences.themeMode == .dark)
    }

    @Test func `Wipe deletes transfer caches and forgets the active import`() async throws {
        let h = try Harness()
        let exports = h.cachesDirectory.appending(path: "exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: exports.appending(path: "e.csv"))
        h.jobs.set(jobDto().importJob(fallbackFormat: .pocketCsv))
        await h.wiper.wipe()
        #expect(!FileManager.default.fileExists(atPath: exports.path))
        #expect(h.jobs.current == nil)
    }

    @Test func `Wipe runs the injected steps in the plan's order`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        let log = LockedLog()
        let sessionStore = h.sessionStore
        let wiper = LocalDataWiper(
            database: h.database,
            cancelAllWork: { log.append("cancel") },
            clearTables: {
                // First pass with the token still stored, the second (share extension) after it is cleared.
                let first = !log.entries.contains("tables")
                #expect((sessionStore.current != nil) == first)
                log.append("tables")
            },
            deleteFiles: { log.append("files") },
            transferDirectories: [],
            sessionStore: h.sessionStore, preferences: h.preferences, importJobs: h.jobs)
        await wiper.wipe()
        #expect(log.entries == ["cancel", "tables", "files", "tables", "files"])
        #expect(h.sessionStore.current == nil)
    }

    @Test func `A failed second table clear reports the wipe as failed`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        struct Boom: Error {}
        let passes = Mutex(0)
        let wiper = LocalDataWiper(
            database: h.database, cancelAllWork: {},
            clearTables: {
                let pass = passes.withLock { count -> Int in
                    count += 1
                    return count
                }
                if pass == 2 { throw Boom() }
            },
            deleteFiles: {}, transferDirectories: [], sessionStore: h.sessionStore, preferences: h.preferences,
            importJobs: h.jobs)
        #expect(await wiper.wipe() == false)
    }

    @Test func `A share committed before the token is cleared is removed by the wipe's second clear`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        let sessionStore = h.sessionStore
        let database = h.database
        let tokenAtSecondClear = LockedLog()
        let clears = Mutex(0)
        let wiper = LocalDataWiper(
            database: database,
            cancelAllWork: {},
            clearTables: {
                let pass = clears.withLock { count -> Int in
                    count += 1
                    return count
                }
                if pass == 2 { tokenAtSecondClear.append(sessionStore.current == nil ? "none" : "still") }
                try await database.write { try MaintenanceDao.wipeAll($0) }
            },
            // The extension commits its row while the files go, after the first clear, token still stored.
            deleteFiles: {
                guard clears.withLock({ $0 }) == 1 else { return }
                try? await database.write { db in
                    try db.execute(
                        sql: """
                            INSERT INTO pending_ops (op_id, type, payload, created_at)
                            VALUES ('share-op', 'item.add', '{}', 0)
                            """)
                }
            },
            transferDirectories: [], sessionStore: h.sessionStore, preferences: h.preferences, importJobs: h.jobs)
        await wiper.wipe()
        #expect(tokenAtSecondClear.entries == ["none"])
        #expect(try await h.pendingOpCount() == 0)
    }

    @Test func `A failed table clear still clears the token, and the next sign in wipes`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        try await h.insertItem()
        struct Boom: Error {}
        let wiper = LocalDataWiper(
            database: h.database, cancelAllWork: {}, clearTables: { throw Boom() }, deleteFiles: {},
            transferDirectories: [], sessionStore: h.sessionStore, preferences: h.preferences, importJobs: h.jobs)
        await wiper.wipe()
        #expect(h.sessionStore.current == nil)
        #expect(h.preferences.accountEmail == nil)
        // Data left behind has no owner now, so signing in (as anyone) wipes it.
        #expect(await h.signIn("a@b.co") == .success)
        #expect(try await h.itemCount() == 0)
    }

    @Test func `Delete account wipes after the server confirms`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        try await h.insertItem()
        let account = LiveAccountRepository(api: h.api, auth: h.auth)
        h.api.configure { $0.deleteAccount = {} }
        #expect(await account.deleteAccount() == .deleted)
        #expect(try await h.itemCount() == 0)
        #expect(h.sessionStore.current == nil)
    }

    @Test func `A deletion answered after another account signed in leaves that account alone`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        let account = LiveAccountRepository(api: h.api, auth: h.auth)
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        h.api.configure {
            $0.deleteAccount = {
                enteredContinuation.yield()
                for await _ in release { break }
            }
        }
        let deletion = Task { await account.deleteAccount() }
        for await _ in entered { break }
        #expect(await h.signIn("c@d.co") == .success)
        try await h.insertItem()
        releaseContinuation.yield()
        _ = await deletion.value
        #expect(h.sessionStore.current?.email == "c@d.co")
        #expect(try await h.itemCount() == 1)
    }

    @Test func `Failed account deletion keeps data and a 401 expires the session`() async throws {
        let h = try Harness()
        _ = await h.signIn("a@b.co")
        try await h.insertItem()
        let account = LiveAccountRepository(api: h.api, auth: h.auth)
        h.api.configure { $0.deleteAccount = { throw httpError(500) } }
        #expect(await account.deleteAccount() == .failed(.server))
        h.api.configure { $0.deleteAccount = { throw httpError(401) } }
        #expect(await account.deleteAccount() == .failed(.unauthorized))
        #expect(try await h.itemCount() == 1)
        #expect(h.sessionStore.current?.expired == true)
    }

    @Test func `Connected clients come from me, nil on failure`() async throws {
        let h = try Harness()
        let account = LiveAccountRepository(api: h.api, auth: h.auth)
        h.api.configure { $0.me = { meDto(extensionClient: true, android: false, ios: true) } }
        #expect(
            await account.connectedClients() == ConnectedClients(extensionClient: true, android: false, ios: true))
        h.api.configure { $0.me = { throw ApiError.transport(.timedOut) } }
        #expect(await account.connectedClients() == nil)
    }
}

final class LockedLog: Sendable {
    private let storage = NSLock()
    private nonisolated(unsafe) var values: [String] = []
    func append(_ value: String) { storage.withLock { values.append(value) } }
    var entries: [String] { storage.withLock { values } }
}
