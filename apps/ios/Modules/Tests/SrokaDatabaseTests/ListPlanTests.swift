import Foundation
import GRDB
import SrokaCore
import Testing

@testable import SrokaDatabase

/// The list queries must be index-driven: no full scan of `items` (alias `i`). Port of Android's
/// `ListPlanTest`.
struct ListPlanTests {
    let database: AppDatabase

    init() throws {
        database = try makeDatabase()
    }

    private func plan(_ query: ItemQuery) throws -> String {
        let built = ItemSQL.list(query)
        return try database.writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(built.sql)", arguments: built.arguments)
                .map { $0["detail"] as String }
                .joined(separator: "\n")
        }
    }

    private func scansItems(_ plan: String) -> Bool {
        plan.split(separator: "\n").contains { line in
            line == "SCAN i" || line.hasPrefix("SCAN i ")
        }
    }

    @Test(arguments: LibrarySortOrder.allCases)
    func `List queries do not scan items`(sort: LibrarySortOrder) throws {
        for tab in LibraryTab.allCases {
            let queries = [
                ItemQuery(tab: tab, sort: sort),
                ItemQuery(tab: tab, sort: sort, favoritesOnly: true, maxReadingMinutes: 9),
                ItemQuery(tab: tab, search: "x", sort: sort),
                ItemQuery(tab: tab, tag: "x", sort: sort, favoritesOnly: true),
                ItemQuery(tab: tab, tag: "x", search: "x", sort: sort, maxReadingMinutes: 9),
            ]
            for query in queries {
                let plan = try plan(query)
                #expect(!scansItems(plan), "full scan of items for \(query):\n\(plan)")
            }
        }
        for query in [
            ItemQuery(tab: nil, tag: "x", sort: sort), ItemQuery(tab: nil, tag: "x", search: "x", sort: sort),
        ] {
            let plan = try plan(query)
            #expect(!scansItems(plan), "full scan of items for \(query):\n\(plan)")
        }
    }

    @Test(arguments: [LibrarySortOrder.newest, .oldest])
    func `Newest and oldest use a sort index without a temp sort`(sort: LibrarySortOrder) throws {
        for tab in LibraryTab.allCases {
            let plan = try plan(ItemQuery(tab: tab, sort: sort))
            #expect(plan.contains("index_items_"), "\(plan)")
            #expect(!plan.contains("TEMP B-TREE FOR ORDER BY"), "temp sort:\n\(plan)")
        }
    }
}
