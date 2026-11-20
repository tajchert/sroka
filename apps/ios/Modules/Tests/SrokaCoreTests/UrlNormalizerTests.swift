import Testing

@testable import SrokaCore

/// Mirrors `packages/shared/src/url.test.ts` and Android's `UrlNormalizerTest`, plus differential vectors
/// (`UrlVectors.swift`) computed with the server's WHATWG URL parser.
struct UrlNormalizerTests {
    private let sharedCases: [(String, String)] = [
        ("HTTPS://Example.COM/Path?b=2&a=1#frag", "https://example.com/Path?a=1&b=2"),
        ("https://example.com:443/x", "https://example.com/x"),
        ("http://example.com:80/x", "http://example.com/x"),
        ("http://example.com:8080/x", "http://example.com:8080/x"),
        ("https://example.com", "https://example.com/"),
        ("https://example.com/post?utm_source=x&utm_Medium=y&id=5", "https://example.com/post?id=5"),
        (
            "https://example.com/?fbclid=1&gclid=2&dclid=3&msclkid=4&mc_eid=5&mc_cid=6&igshid=7&ref_src=8&_hsenc=9&_hsmktg=10&yclid=11",
            "https://example.com/"
        ),
        ("https://example.com/a/", "https://example.com/a/"),
        ("https://www.example.com/a", "https://www.example.com/a"),
        ("https://user:pw@example.com/a", "https://example.com/a"),
        ("https://example.com./a", "https://example.com/a"),
        ("https://example.com/a?z=1&a=2&z=0", "https://example.com/a?a=2&z=1&z=0"),
        ("  https://example.com/a  ", "https://example.com/a"),
        ("https://bücher.de/", "https://xn--bcher-kva.de/"),
        ("https://example.com/a?q=hello world", "https://example.com/a?q=hello+world"),
        // api.md §13 example
        ("HTTPS://Example.COM:443/Path?utm_source=x&b=2&a=1#top", "https://example.com/Path?a=1&b=2"),
    ]

    @Test func `Shared vectors normalise`() {
        for (input, expected) in sharedCases {
            #expect(UrlNormalizer.normalize(input) == expected, "\(input)")
        }
    }

    @Test func `Normalising is idempotent`() {
        for (_, output) in sharedCases { #expect(UrlNormalizer.normalize(output) == output) }
    }

    @Test func `Non-http input is rejected`() {
        #expect(UrlNormalizer.normalize("ftp://x.com/") == nil)
        #expect(UrlNormalizer.normalize("javascript:alert(1)") == nil)
        #expect(UrlNormalizer.normalize("not a url") == nil)
        #expect(UrlNormalizer.normalize("https://") == nil)
    }

    @Test func `Differential vectors from the server parser normalise identically`() {
        for (input, expected) in urlVectors + urlVectorsRound2 {
            #expect(UrlNormalizer.normalize(input) == expected, "\(input.debugDescription)")
        }
    }

    @Test func `Differential vectors agree on what is an http url`() {
        for (input, expected) in httpUrlVectorsRound2 {
            #expect(UrlNormalizer.isHttpUrl(input) == expected, "\(input.debugDescription)")
        }
        for (input, expected) in httpUrlVectors {
            #expect(UrlNormalizer.isHttpUrl(input) == expected, "\(input.debugDescription)")
        }
    }

    @Test func `Differential vectors extract the same first url`() {
        for (input, expected) in extractVectors {
            #expect(UrlNormalizer.extractFirstUrl(input) == expected, "\(input.debugDescription)")
        }
    }

    @Test func `Is http url`() {
        #expect(UrlNormalizer.isHttpUrl("https://a.b"))
        #expect(!UrlNormalizer.isHttpUrl("mailto:a@b.c"))
        #expect(!UrlNormalizer.isHttpUrl("/relative"))
    }

    @Test func `Url hash is sha256 hex`() {
        #expect(UrlNormalizer.urlHash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func `Url hash of the api example is stable`() throws {
        let canonical = try #require(UrlNormalizer.normalize("HTTPS://Example.COM:443/Path?utm_source=x&b=2&a=1#top"))
        #expect(canonical == "https://example.com/Path?a=1&b=2")
        #expect(UrlNormalizer.urlHash(canonical).count == 64)
    }

    @Test func `Display domain drops www`() {
        #expect(UrlNormalizer.displayDomain("https://www.Example.com/a") == "example.com")
        #expect(UrlNormalizer.displayDomain("nope") == "")
        #expect(UrlNormalizer.hostOf("https://User@Example.com:8080/a") == "example.com")
        #expect(UrlNormalizer.hostOf("ftp://example.com") == nil)
    }

    @Test func `Extract finds a url in share text`() {
        #expect(
            UrlNormalizer.extractFirstUrl("Great read https://example.com/a?b=1 via @app")
                == "https://example.com/a?b=1"
        )
    }

    @Test func `Extract strips trailing punctuation and unbalanced brackets`() {
        #expect(UrlNormalizer.extractFirstUrl("(see https://example.com/x).") == "https://example.com/x")
        #expect(
            UrlNormalizer.extractFirstUrl("https://en.wikipedia.org/wiki/Foo_(bar)")
                == "https://en.wikipedia.org/wiki/Foo_(bar)"
        )
        #expect(UrlNormalizer.extractFirstUrl("\"https://example.com/q\"!") == "https://example.com/q")
    }

    @Test func `Extract stops at unicode separators`() {
        #expect(UrlNormalizer.extractFirstUrl("Read https://example.com/a\u{00A0}now") == "https://example.com/a")
        #expect(UrlNormalizer.extractFirstUrl("https://example.com/b\u{2028}next line") == "https://example.com/b")
        #expect(UrlNormalizer.extractFirstUrl("https://example.com/c\u{3000}x") == "https://example.com/c")
    }

    @Test func `Extract returns nil when there is no url`() {
        #expect(UrlNormalizer.extractFirstUrl("no links here") == nil)
    }

    @Test func `Query pairs keep their order within one name`() {
        #expect(UrlNormalizer.normalize("https://e.com/?b=2&a=2&b=1&a=1") == "https://e.com/?a=2&a=1&b=2&b=1")
    }

    @Test func `Fragment inside query text is dropped before parsing the query`() {
        #expect(UrlNormalizer.normalize("https://e.com/?a=1#b=2") == "https://e.com/?a=1")
    }
}
