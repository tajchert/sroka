import Dependencies
import Foundation
import SrokaCore
import Testing

@testable import SrokaTesting

struct FakeLibraryRepositoryTests {
    @Test func `My List shows unread items newest first`() async throws {
        let library = FakeLibraryRepository()
        var iterator = library.observeItems(ItemQuery(tab: .myList), limit: 50).makeAsyncIterator()
        let page = try #require(await iterator.next())
        #expect(page.items.allSatisfy { $0.status == .unread })
        #expect(page.items.map(\.savedAt) == page.items.map(\.savedAt).sorted(by: >))
        #expect(!page.hasMore)
    }

    @Test func `Archiving emits an updated page`() async throws {
        let library = FakeLibraryRepository()
        var iterator = library.observeItems(ItemQuery(tab: .archive), limit: 50).makeAsyncIterator()
        let before = try #require(await iterator.next())
        await library.setStatus(id: Fixtures.longRead.id, status: .archived)
        let after = try #require(await iterator.next())
        #expect(after.items.count == before.items.count + 1)
        #expect(library.item(id: Fixtures.longRead.id)?.archivedAt == Fixtures.now)
    }

    @Test func `Saving a known URL reports already saved`() async {
        let library = FakeLibraryRepository()
        let result = await library.save(url: Fixtures.archived.url, title: nil, tags: [], source: .share)
        #expect(result == .saved(itemId: Fixtures.archived.id, alreadySaved: true))
        #expect(library.item(id: Fixtures.archived.id)?.status == .unread)
    }

    @Test func `Saving an invalid URL fails`() async {
        let result = await FakeLibraryRepository().save(url: "not a url", title: nil, tags: [], source: .manual)
        #expect(result == .invalidUrl)
    }

    @Test func `Search matches titles and excerpts`() async throws {
        let library = FakeLibraryRepository()
        var iterator = library.observeSearch("magpies", scope: .all, limit: 10).makeAsyncIterator()
        let page = try #require(await iterator.next())
        #expect(page.results.first?.id == Fixtures.shortNews.id)
        #expect(page.results.first?.matchIn == .both)
    }
}

struct FakeTagRepositoryTests {
    @Test func `Tag counts match the fixtures`() async throws {
        let fakes = Fakes()
        var iterator = fakes.tags.observeTags().makeAsyncIterator()
        #expect(try #require(await iterator.next()) == Fixtures.tags)
    }

    @Test func `Renaming a tag merges case-insensitive duplicates`() async {
        let fakes = Fakes()
        #expect(await fakes.tags.rename(from: "Birds", to: "science") == .done)
        #expect(fakes.library.item(id: Fixtures.shortNews.id)?.tags == ["science"])
    }
}

struct FakeAuthRepositoryTests {
    @Test func `The valid code signs in`() async throws {
        let auth = FakeAuthRepository(session: .signedOut)
        #expect(await auth.signIn(email: "a@b.co", code: "000000") == .failure(.invalidCode))
        #expect(await auth.signIn(email: "a@b.co", code: "123 456") == .success)
        var iterator = auth.session.makeAsyncIterator()
        #expect(try #require(await iterator.next()) == .signedIn(email: "a@b.co"))
    }
}

struct UseFakesTests {
    @Test func `useFakes installs every domain dependency`() async {
        let fakes = Fakes.empty
        await withDependencies {
            $0.useFakes(fakes)
        } operation: {
            @Dependency(\.libraryRepository) var library
            @Dependency(\.syncController) var sync
            _ = await library.save(url: "https://example.com/x", title: "X", tags: ["A"], source: .manual)
            sync.requestSync()
        }
        #expect(fakes.library.items.value.count == 1)
        #expect(fakes.syncController.calls.calls == [.requestSync])
    }
}
