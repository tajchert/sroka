import Foundation
import SrokaCore
import Testing

@testable import SrokaNetwork

struct ErrorAndDecodingTests {
    @Test func `The v1 error shape maps to code, message and Retry-After`() async {
        let harness = Harness { _ in
            .json(#"{"error":"rate_limited","message":"slow down"}"#, status: 429, headers: ["Retry-After": "30"])
        }
        let error = await apiError { try await harness.api.me() }
        #expect(error == .http(status: 429, code: "rate_limited", message: "slow down", retryAfter: 30))
        #expect(error?.remoteFailure == .rateLimited)
    }

    @Test func `The Better Auth error shape maps to code, message and X-Retry-After`() async {
        let harness = Harness(token: nil) { _ in
            .json(
                #"{"code":"TOO_MANY_ATTEMPTS","message":"Too many attempts"}"#, status: 429,
                headers: ["X-Retry-After": "12"])
        }
        let error = await apiError { try await harness.api.signIn(email: "a@b.c", otp: "000000") }
        #expect(error == .http(status: 429, code: "TOO_MANY_ATTEMPTS", message: "Too many attempts", retryAfter: 12))
        #expect(error?.retryAfter == 12 && error?.code == "TOO_MANY_ATTEMPTS" && error?.status == 429)
    }

    @Test func `Retry-After wins over X-Retry-After and junk is ignored`() async {
        let both = Harness { _ in .json("{}", status: 429, headers: ["Retry-After": "5", "X-Retry-After": "99"]) }
        #expect(await apiError { try await both.api.me() }?.retryAfter == 5)
        let junk = Harness { _ in .json("{}", status: 429, headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]) }
        #expect(await apiError { try await junk.api.me() }?.retryAfter == nil)
    }

    @Test func `Invalid one-time codes are typed by their code`() async {
        let harness = Harness(token: nil) { _ in .json(#"{"code":"INVALID_OTP","message":"Invalid OTP"}"#, status: 400)
        }
        let error = await apiError { try await harness.api.signIn(email: "a@b.c", otp: "1") }
        #expect(error?.code == "INVALID_OTP")
        #expect(error?.remoteFailure == .server)
    }

    @Test func `Status codes map onto the domain failure`() async {
        func failure(_ status: Int, body: String = "") async -> RemoteFailure? {
            let harness = Harness { _ in .json(body, status: status) }
            return await apiError { try await harness.api.me() }?.remoteFailure
        }
        #expect(await failure(401, body: #"{"error":"unauthorized"}"#) == .unauthorized)
        #expect(await failure(429) == .rateLimited)
        #expect(await failure(500) == .server)
        #expect(await failure(503, body: "<html>bad gateway</html>") == .server)
        #expect(await failure(404) == .server)
    }

    @Test func `Transport errors map to network`() async {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost] {
            let harness = Harness { _ in .failure(code) }
            let error = await apiError { try await harness.api.me() }
            #expect(error == .transport(code))
            #expect(error?.remoteFailure == .network)
        }
    }

    @Test func `Resync required is recognised`() async {
        let harness = Harness { _ in .json(#"{"error":"resync_required"}"#, status: 410) }
        let error = await apiError { try await harness.api.pull(cursor: 5, limit: 500, full: false) }
        #expect(error?.isResyncRequired == true)
        #expect(error?.isUnauthorized == false)
    }

    @Test func `Undecodable success bodies are malformed responses`() async {
        let harness = Harness { _ in .json("<html>") }
        #expect(await apiError { try await harness.api.me() } == .malformedResponse)
        #expect(await apiError { try await harness.api.pull(cursor: 0, limit: 1, full: false) } == .malformedResponse)
        #expect(ApiError.malformedResponse.remoteFailure == .server)
    }

    @Test func `PDF upload errors map from status and code`() {
        func error(_ status: Int, _ code: String? = nil) -> PdfUploadError {
            ApiError.http(status: status, code: code, message: nil, retryAfter: nil).pdfUploadError
        }
        #expect(error(413, "payload_too_large") == .tooLarge)
        #expect(error(415, "unsupported_media_type") == .notPdf)
        #expect(error(409, "storage_full") == .storageFull)
        #expect(error(409, "other") == .unknown)
        #expect(error(401) == .auth)
        #expect(error(411, "length_required") == .unknown)
        #expect(error(500) == .unknown)
        #expect(ApiError.transport(.timedOut).pdfUploadError == .network)
    }

    // MARK: Tolerant decoding

    @Test func `Pull answers tolerate unknown keys, unknown enum strings and missing fields`() async throws {
        let json = """
            {"cursor":120,"hasMore":true,"futureTopLevel":{"a":1},
             "items":[
               {"id":"i1","url":"https://a.b/","parseStatus":"quantum","status":"snoozed","kind":"video","source":"carrier-pigeon","extraKey":[1,2],"progress":1,"savedAt":1760400723120,"tags":["a","b"],"seq":7},
               {"id":"i2","url":"https://c.d/","title":null,"wordCount":null,"progressAnchor":"oops","isFavorite":"yes"},
               {"id":"i3","url":"https://e.f/","kind":"pdf","fileName":"x.pdf","fileSize":1234,"parseStatus":"ok","status":"archived","archivedAt":5,"isFavorite":true}
             ],
             "tags":[{"id":"t1","name":"Swift","seq":3,"color":"red"}],
             "deleted":{"items":["gone"],"tags":[],"other":["x"]}}
            """
        let harness = Harness { _ in .json(json) }
        let page = try await harness.api.pull(cursor: 0, limit: 500, full: false)
        #expect(page.cursor == 120 && page.hasMore)
        #expect(page.items.map(\.id) == ["i1", "i2", "i3"])

        let first = page.items[0]
        #expect(first.parseStatusValue == .pending && first.statusValue == .unread)
        #expect(first.kindValue == .article && first.sourceValue == .unknown)
        #expect(
            first.progress == 1 && first.savedAt == 1_760_400_723_120 && first.tags == ["a", "b"] && first.seq == 7)

        let second = page.items[1]
        #expect(second.title == nil && second.wordCount == nil && second.progressAnchor == nil)
        #expect(second.isFavorite == false && second.parseStatus == "pending" && second.status == "unread")
        #expect(
            second.kind == "article" && second.tags.isEmpty && second.savedAt == 0 && second.contentPrivate == false)

        let third = page.items[2]
        #expect(third.kindValue == .pdf && third.fileName == "x.pdf" && third.fileSize == 1234)
        #expect(
            third.parseStatusValue == .ok && third.statusValue == .archived && third.archivedAt == 5 && third.isFavorite
        )

        #expect(page.tags == [TagDto(id: "t1", name: "Swift", count: nil, seq: 3)])
        #expect(page.deleted == DeletedDto(items: ["gone"], tags: []))
    }

    @Test func `Pull answers without optional collections still decode`() async throws {
        let harness = Harness { _ in .json(#"{"cursor":1}"#) }
        let page = try await harness.api.pull(cursor: 0, limit: 500, full: false)
        #expect(page.items.isEmpty && page.tags.isEmpty && page.deleted == DeletedDto() && !page.hasMore)
    }

    @Test func `An item without an id is a malformed page`() async {
        let harness = Harness { _ in .json(#"{"cursor":1,"items":[{"url":"https://a.b/"}]}"#) }
        #expect(await apiError { try await harness.api.pull(cursor: 0, limit: 1, full: false) } == .malformedResponse)
    }

    @Test func `Push answers keep unknown rejection reasons and aliases`() async throws {
        let json =
            #"{"applied":["a","b"],"rejected":[{"opId":"c","reason":"brand_new_reason","detail":1}],"aliases":{"client-1":"server-1"},"cursor":55,"z":0}"#
        let harness = Harness { _ in .json(json) }
        let response = try await harness.api.push(payloads: ["{}"])
        #expect(response.applied == ["a", "b"])
        #expect(response.rejected == [RejectedOpDto(opId: "c", reason: "brand_new_reason")])
        #expect(response.aliases == ["client-1": "server-1"] && response.cursor == 55)
    }

    @Test func `Me tolerates older servers without clients and with unknown keys`() async throws {
        let harness = Harness { _ in
            .json(
                #"{"user":{"id":"u1","email":"e@x.y","name":null,"emailVerified":true,"createdAt":9},"stats":{"unread":2,"archived":3,"favorites":1,"tags":4},"isAdmin":false}"#
            )
        }
        let me = try await harness.api.me()
        #expect(
            me.user
                == (try JSONDecoder().decode(
                    MeUserDto.self, from: Data(#"{"id":"u1","email":"e@x.y","emailVerified":true,"createdAt":9}"#.utf8)))
        )
        #expect(me.stats == MeStatsDto(unread: 2, archived: 3, favorites: 1, tags: 4))
        #expect(me.clients == MeClientsDto())
        let withClients = Harness { _ in
            .json(
                #"{"user":{"id":"u1","email":"e@x.y"},"clients":{"extension":true,"android":false,"ios":true,"watch":true}}"#
            )
        }
        let clients = try await withClients.api.me().clients
        #expect(clients == MeClientsDto(chromeExtension: true, android: false, ios: true))
    }

    @Test func `Config exposes the iOS minimum version and tolerates its absence`() async throws {
        let full = Harness { _ in
            .json(
                #"{"appOrigin":"https://sroka.app","minVersions":{"android":3,"ios":12,"watch":1},"limits":{"maxOpsPerPush":250}}"#
            )
        }
        let config = try await full.api.config()
        #expect(config.minVersions == MinVersionsDto(android: 3, ios: 12) && config.limits.maxOpsPerPush == 250)
        #expect(config.appOrigin == "https://sroka.app")
        let bare = Harness { _ in .json("{}") }
        let defaults = try await bare.api.config()
        #expect(defaults.minVersions.ios == nil && defaults.limits.maxOpsPerPush == Limits.maxOpsPerPush)
    }

    @Test func `Import jobs map to the domain with unknown values handled`() throws {
        let job = try JSONDecoder().decode(
            JobDto.self,
            from: Data(
                #"{"id":"j1","kind":"import","status":"reticulating","format":"mystery","total":null,"done":4,"skipped":1,"error":null,"createdAt":1000,"updatedAt":3000,"x":1}"#
                    .utf8))
        let domain = job.importJob(fallbackFormat: .netscapeHtml)
        #expect(domain.status == .running && domain.format == .netscapeHtml && domain.total == nil)
        #expect(domain.done == 4 && domain.skipped == 1 && domain.error == nil)
        #expect(
            domain.createdAt == Date(timeIntervalSince1970: 1) && domain.updatedAt == Date(timeIntervalSince1970: 3))
        let done = try JSONDecoder().decode(
            JobDto.self, from: Data(#"{"id":"j2","status":"done","format":"pocket_csv","total":10,"done":10}"#.utf8))
        #expect(done.importJob(fallbackFormat: .netscapeHtml).format == .pocketCsv)
        #expect(JobStatus(wire: done.status).isFinished)
    }
}
