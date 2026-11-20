import Foundation
import SrokaCore
import Testing

@testable import SrokaNetwork

/// Runs `body` and returns the `ApiError` it throws (nil if it succeeds or throws something else).
func apiError<T>(_ body: () async throws -> T) async -> ApiError? {
    do {
        _ = try await body()
        return nil
    } catch let error as ApiError {
        return error
    } catch {
        return nil
    }
}

struct RequestTests {
    /// Every endpoint, called once; failures are ignored because only the outgoing requests matter here.
    private func callEveryEndpoint(_ api: HTTPSrokaAPI) async throws {
        let file = try temporaryFile(Data("%PDF-1.4 x".utf8), name: "every.pdf")
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: directory)
        }
        try? await api.sendOtp(email: "a@b.c")
        _ = try? await api.signIn(email: "a@b.c", otp: "123456")
        try? await api.signOut()
        _ = try? await api.push(payloads: [#"{"a":1}"#])
        _ = try? await api.pull(cursor: 0, limit: 500, full: false)
        _ = try? await api.item(id: "i1")
        _ = try? await api.contentUrls(itemId: "i1")
        _ = try? await api.uploadPdf(file: file, fileName: "a.pdf", tags: ["t"], source: .share, onProgress: nil)
        _ = try? await api.uploadThumbnail(itemId: "i1", data: Data([0xFF, 0xD8, 0xFF]), contentType: "image/jpeg")
        _ = try? await api.me()
        try? await api.deleteAccount()
        _ = try? await api.createImport(source: file, fileName: "a.csv", mimeType: "text/csv", format: .pocketCsv)
        _ = try? await api.importJob(id: "j1")
        _ = try? await api.export(format: .csv, to: directory.appendingPathComponent("e.csv"))
        _ = try? await api.config()
    }

    @Test func `Every API call sends bearer, device and user agent and never Origin or cookies`() async throws {
        let harness = Harness.always()
        try await callEveryEndpoint(harness.api)
        #expect(harness.requests.count == 15)
        for request in harness.requests {
            let label = "\(request.method) \(request.path)"
            #expect(request.header("Authorization") == "Bearer \(Harness.token)", "\(label)")
            #expect(request.header("X-Sroka-Device") == Harness.device, "\(label)")
            #expect(request.header("User-Agent") == Harness.userAgent, "\(label)")
            #expect(request.header("Origin") == nil, "\(label)")
            #expect(request.header("Cookie") == nil, "\(label)")
            #expect(request.handlesCookies == false, "\(label)")
        }
    }

    @Test func `Signed out calls carry no Authorization header`() async throws {
        let harness = Harness(token: nil) { _ in .json(#"{"minVersions":{"ios":12}}"#) }
        _ = try await harness.api.config()
        #expect(harness.last.header("Authorization") == nil)
        #expect(harness.last.header("X-Sroka-Device") == Harness.device)
    }

    @Test func `Endpoint methods and paths`() async throws {
        let harness = Harness.always()
        try? await harness.api.sendOtp(email: "a@b.c")
        _ = try? await harness.api.signIn(email: "a@b.c", otp: "1")
        try? await harness.api.signOut()
        _ = try? await harness.api.me()
        try? await harness.api.deleteAccount()
        _ = try? await harness.api.config()
        _ = try? await harness.api.importJob(id: "j1")
        let seen = harness.requests.map { "\($0.method) \($0.path)" }
        #expect(
            seen == [
                "POST /api/auth/email-otp/send-verification-otp",
                "POST /api/auth/sign-in/email-otp",
                "POST /api/auth/sign-out",
                "GET /v1/me",
                "DELETE /v1/account",
                "GET /v1/config",
                "GET /v1/imports/j1",
            ])
    }

    @Test func `Auth bodies`() async throws {
        let harness = Harness.always()
        try? await harness.api.sendOtp(email: "a@b.c")
        let send = try #require(JSONSerialization.jsonObject(with: harness.last.body) as? [String: String])
        #expect(send == ["email": "a@b.c", "type": "sign-in"])
        _ = try? await harness.api.signIn(email: "a@b.c", otp: "123456")
        let verify = try #require(JSONSerialization.jsonObject(with: harness.last.body) as? [String: String])
        #expect(verify == ["email": "a@b.c", "otp": "123456"])
        #expect(harness.last.header("Content-Type")?.hasPrefix("application/json") == true)
        try? await harness.api.deleteAccount()
        #expect(harness.last.bodyText == #"{"confirm":"DELETE"}"#)
    }

    @Test func `Sign in returns the set-auth-token header verbatim`() async throws {
        let token = "abc.def_ghi-123==.sig="
        let harness = Harness(token: nil) { _ in
            .json(#"{"user":{"email":"Real@Example.com"},"token":"ignored"}"#, headers: ["set-auth-token": token])
        }
        let result = try await harness.api.signIn(email: "typed@example.com", otp: "123456")
        #expect(result == SignInResult(token: token, userEmail: "Real@Example.com"))
    }

    @Test func `Sign in falls back to the typed email and fails without the token header`() async throws {
        let ok = Harness(token: nil) { _ in .json("not json", headers: ["Set-Auth-Token": "tok"]) }
        #expect(try await ok.api.signIn(email: "me@x.y", otp: "1") == SignInResult(token: "tok", userEmail: "me@x.y"))
        let missing = Harness(token: nil) { _ in .json("{}") }
        #expect(await apiError { try await missing.api.signIn(email: "me@x.y", otp: "1") } == .malformedResponse)
    }

    @Test func `Sign out uses a five second timeout`() async throws {
        let harness = Harness.always()
        try await harness.api.signOut()
        #expect(harness.last.timeout == 5)
    }

    @Test func `Pull builds its query`() async throws {
        let harness = Harness { _ in .json(#"{"cursor":9,"hasMore":false,"deleted":{}}"#) }
        _ = try await harness.api.pull(cursor: 41, limit: 500, full: false)
        #expect(harness.last.path == "/v1/sync/pull")
        #expect(harness.last.query == "cursor=41&limit=500")
        _ = try await harness.api.pull(cursor: 0, limit: 100, full: true)
        #expect(harness.last.query == "cursor=0&limit=100&full=1")
    }

    @Test func `Push sends the canonical payloads byte for byte`() async throws {
        let harness = Harness { _ in .json(#"{"applied":["a"],"rejected":[],"aliases":{},"cursor":3}"#) }
        let payloads = [
            #"{"at":1,"itemId":"i1","opId":"a","type":"item.delete"}"#,
            #"{"at":2,"opId":"b","tag":"żółw/x","type":"tag.delete"}"#,
        ]
        let response = try await harness.api.push(payloads: payloads)
        #expect(response.applied == ["a"] && response.cursor == 3)
        #expect(harness.last.method == "POST" && harness.last.path == "/v1/sync/push")
        #expect(harness.last.bodyText == #"{"deviceId":"\#(Harness.device)","ops":[\#(payloads[0]),\#(payloads[1])]}"#)
        #expect(harness.last.header("Content-Type")?.hasPrefix("application/json") == true)
        _ = try JSONSerialization.jsonObject(with: harness.last.body)
    }

    @Test func `Push of typed ops uses their canonical payloads`() async throws {
        let harness = Harness { _ in .json(#"{"applied":[],"rejected":[],"aliases":{},"cursor":0}"#) }
        let op = WireOp.delete(.init(opId: "o1", itemId: "i1", at: 5))
        _ = try await harness.api.push(ops: [op])
        #expect(harness.last.bodyText.contains(op.payload))
    }

    @Test func `Push refuses oversized batches without calling the server`() async {
        let harness = Harness.always()
        let tooMany = Array(repeating: "{}", count: Limits.maxOpsPerPush + 1)
        #expect(await apiError { try await harness.api.push(payloads: tooMany) } == .invalidRequest)
        #expect(harness.requests.isEmpty)
        let atLimit = Array(repeating: "{}", count: Limits.maxOpsPerPush)
        _ = try? await harness.api.push(payloads: atLimit)
        #expect(harness.requests.count == 1)
    }

    @Test func `Item ids are percent-encoded as one path segment`() async throws {
        let harness = Harness.always()
        _ = try? await harness.api.item(id: "a/b c?d")
        #expect(harness.last.path == "/v1/items/a%2Fb%20c%3Fd")
        _ = try? await harness.api.contentUrls(itemId: "x")
        #expect(harness.last.path == "/v1/items/x/content")
    }

    @Test func `Item answers are wrapped in item`() async throws {
        let wrapped = Harness { _ in .json(#"{"item":{"id":"i1","url":"https://a.b/"}}"#) }
        #expect(try await wrapped.api.item(id: "i1").id == "i1")
        let bare = Harness { _ in .json(#"{"id":"i2","url":"https://a.b/"}"#) }
        #expect(await apiError { try await bare.api.item(id: "i2") } == .malformedResponse)
    }

    @Test func `Content urls decode and a missing parse is a typed error`() async throws {
        let ok = Harness { _ in
            .json(
                #"{"articleUrl":"https://c.sroka.app/a","baseUrl":"https://c.sroka.app/","packageUrl":"https://c.sroka.app/p","expiresAt":1760400723120,"documentUrl":"https://c.sroka.app/d.pdf","extra":1}"#
            )
        }
        let urls = try await ok.api.contentUrls(itemId: "i1")
        #expect(urls.articleUrl == "https://c.sroka.app/a" && urls.documentUrl == "https://c.sroka.app/d.pdf")
        #expect(urls.expiresAt == 1_760_400_723_120)
        let pending = Harness { _ in .json(#"{"error":"not_parsed"}"#, status: 409) }
        let error = await apiError { try await pending.api.contentUrls(itemId: "i1") }
        #expect(error?.isNotParsed == true)
    }

    @Test func `Base url may be plain http on localhost and may carry a trailing slash`() async throws {
        let harness = Harness(base: "http://{host}:8787/") { _ in .json(#"{"user":{"id":"u","email":"e@x.y"}}"#) }
        let me = try await harness.api.me()
        #expect(me.user.email == "e@x.y")
        #expect(harness.last.url.scheme == "http")
        #expect(harness.last.path == "/v1/me")
        let nested = Harness(base: "https://{host}/api-root//") { _ in .json("{}") }
        _ = try? await nested.api.config()
        #expect(nested.last.path == "/api-root/v1/config")
    }

    @Test func `Thumbnail upload sends raw bytes with the image type`() async throws {
        let harness = Harness { _ in .json(#"{"item":{"id":"i1","url":"u","leadImageKey":"thumb.webp"}}"#) }
        let bytes = Data("RIFFxxxxWEBPpayload".utf8)
        let item = try await harness.api.uploadThumbnail(itemId: "i1", data: bytes, contentType: "image/webp")
        #expect(item.leadImageKey == "thumb.webp")
        #expect(harness.last.method == "PUT" && harness.last.path == "/v1/items/i1/thumbnail")
        #expect(harness.last.header("Content-Type") == "image/webp")
        #expect(harness.last.body == bytes)
    }

    @Test func `Thumbnail upload refuses other types and oversized images`() async {
        let harness = Harness.always()
        #expect(
            await apiError {
                try await harness.api.uploadThumbnail(itemId: "i", data: Data([1]), contentType: "image/png")
            }
                == .invalidRequest)
        let big = Data(count: Limits.maxThumbnailBytes + 1)
        #expect(
            await apiError { try await harness.api.uploadThumbnail(itemId: "i", data: big, contentType: "image/jpeg") }
                == .invalidRequest)
        #expect(harness.requests.isEmpty)
    }

    @Test func `A hanging request is cancelled with CancellationError`() async {
        let harness = Harness { _ in StubResponse(hang: true) }
        let api = harness.api
        let task = Task { try await api.me() }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @Test func `Info plist allows plain http to local networking only`() throws {
        // Modules/Tests/SrokaNetworkTests/RequestTests.swift -> apps/ios/App/Info.plist
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return }  // not readable from this sandbox
        let root = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let ats = try #require(root["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        #expect(ats["NSAllowsArbitraryLoads"] == nil)
    }
}
