import Foundation
import Testing

@testable import SrokaCore

struct VocabularyTests {
    @Test func `Failure reasons map known codes`() {
        #expect(Vocabulary.failureReason("bot_wall") == "The site blocks Sroka.")
        #expect(Vocabulary.failureReason("paywalled") == "It's for subscribers only.")
        #expect(Vocabulary.failureReason("http_404") == "The page is gone.")
        #expect(Vocabulary.failureReason("http_503") == "The site didn't respond.")
        #expect(Vocabulary.failureReason("not_html") == "It isn't an article.")
    }

    @Test func `Failure reasons are nil for missing or unknown codes`() {
        #expect(Vocabulary.failureReason(nil) == nil)
        #expect(Vocabulary.failureReason("") == nil)
        #expect(Vocabulary.failureReason("readability_empty_xyz") == nil)
    }
}

struct EnumWireTests {
    @Test func `Unknown wire values fall back to defaults`() {
        #expect(ItemStatus(wire: "deleted") == .unread)
        #expect(ItemKind(wire: nil) == .article)
        #expect(ItemSource(wire: "extension") == .extensionSource)
        #expect(DownloadPolicy(wire: "wifi_only") == .wifiOnly)
    }
}

struct LimitsTests {
    @Test func `Titles are trimmed and blank titles become nil`() {
        #expect(Limits.clampTitle("  Hello  ") == "Hello")
        #expect(Limits.clampTitle("   ") == nil)
        #expect(Limits.clampTitle(nil) == nil)
    }

    @Test func `Long titles are cut without splitting a surrogate pair`() throws {
        let title = String(repeating: "a", count: Limits.maxTitleLength - 1) + "😀tail"
        let clamped = try #require(Limits.clampTitle(title))
        #expect(clamped.utf16.count == Limits.maxTitleLength - 1)
    }
}

struct ItemTests {
    @Test func `Item ids follow the shared pattern`() {
        #expect(isValidItemId("01HZX_abc-123"))
        #expect(!isValidItemId(""))
        #expect(!isValidItemId("has space"))
        #expect(!isValidItemId(String(repeating: "a", count: 65)))
    }

    @Test func `Display title falls back to the domain without www`() {
        let item = Item(id: "x", url: "https://www.example.com/a", title: "  ", savedAt: .now)
        #expect(item.displayTitle == "example.com")
        #expect(item.canonicalUrl == "https://www.example.com/a")
    }

    @Test func `Tag keys ignore case and extra whitespace`() {
        #expect(normalizeTagName("  Read   later ") == "Read later")
        #expect(tagKey("Read Later") == tagKey("read later"))
    }
}

struct AppEnvironmentTests {
    @Test func `Environment reads every Info.plist key`() throws {
        let environment = try #require(
            AppEnvironment(infoDictionary: [
                "AppEnvironmentName": "Dev",
                "APIBaseURL": "http://localhost:8787",
                "AppGroupIdentifier": "group.app.sroka.dev",
                "KeychainAccessGroup": "app.sroka.dev.shared",
                "URLScheme": "sroka-dev",
            ])
        )
        #expect(environment.itemURL(id: "abc")?.absoluteString == "sroka-dev://item/abc")
        #expect(environment.itemURL(id: "../etc") == nil)
    }

    @Test func `Environment is nil when a key is missing`() {
        #expect(AppEnvironment(infoDictionary: ["AppEnvironmentName": "Dev"]) == nil)
    }
}
