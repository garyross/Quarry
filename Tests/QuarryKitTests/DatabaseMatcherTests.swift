import Foundation
import Testing
@testable import QuarryKit

struct DatabaseMatcherTests {
    let names = ["information_schema", "mysql", "quarry_demo", "quarry_empty", "quarry_legacy", "shop_demo"]

    func found(_ search: String) -> [String] { DatabaseMatcher.matches(search, in: names).map(\.name) }

    @Test func anEmptySearchListsEveryNameInOrder() {
        #expect(found("") == names)
        #expect(found("\"\"") == names)
    }

    @Test func lettersMatchInOrderButNotTogether() {
        #expect(found("qdm") == ["quarry_demo"])
        #expect(found("mdq") == [])
        #expect(found("QUARRY") == ["quarry_demo", "quarry_empty", "quarry_legacy"])
    }

    @Test func fewerSeparatePartsSortFirst() {
        // "demo" is one part in quarry_demo and shop_demo; "emp" one part in quarry_empty.
        #expect(found("demo") == ["quarry_demo", "shop_demo"])
        #expect(found("sq").first == "mysql")
    }

    @Test func neighbouringLettersMergeIntoOneRange() throws {
        let match = try #require(DatabaseMatcher.matches("qdemo", in: ["quarry_demo"]).first)
        #expect(match.ranges.map { String(match.name[$0]) } == ["q", "demo"])
        let exact = try #require(DatabaseMatcher.matches("MySQL", in: ["mysql"]).first)
        #expect(exact.ranges == [exact.name.startIndex..<exact.name.endIndex])
    }

    @Test func aQuotedSearchFindsTheTextAsTyped() {
        #expect(DatabaseMatcher.isWordSearch("\"demo\""))
        #expect(DatabaseMatcher.isWordSearch("'demo'"))
        #expect(!DatabaseMatcher.isWordSearch("\"demo'"))
        #expect(!DatabaseMatcher.isWordSearch("\""))
        #expect(found("\"qd\"") == [])
        #expect(found("'_demo'") == ["quarry_demo", "shop_demo"])
    }

    @Test func accentsAndWidthAreIgnored() {
        #expect(DatabaseMatcher.matches("cafe", in: ["café_db"]).count == 1)
        #expect(DatabaseMatcher.matches("ｓｈｏｐ", in: ["shop"]).count == 1)
    }
}
