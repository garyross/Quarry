import Foundation
import Testing
@testable import QuarryKit

@Suite("Character sets and New Database")
struct CharsetCatalogTests {
    private let catalog = CharsetCatalog(
        charsets: [ServerCharset(name: "latin1", description: "cp1252 West European", defaultCollation: "latin1_swedish_ci"),
                   ServerCharset(name: "ascii", description: "", defaultCollation: "ascii_general_ci"),
                   ServerCharset(name: "utf8mb3", description: "UTF-8 Unicode", defaultCollation: "utf8mb3_general_ci"),
                   ServerCharset(name: "utf8mb4", description: "UTF-8 Unicode", defaultCollation: "utf8mb4_uca1400_ai_ci")],
        collations: [("utf8mb4_bin", "utf8mb4"), ("utf8mb4_uca1400_ai_ci", "utf8mb4"), ("utf8mb4_general_ci", "utf8mb4"),
                     ("latin1_swedish_ci", "latin1"), ("latin1_bin", "latin1"), ("latin1_bin", "latin1"),
                     ("ascii_general_ci", "ascii")],
        serverCharset: "utf8mb4", serverCollation: "utf8mb4_general_ci")

    @Test func utf8ComesFirst() {
        #expect(catalog.charsets.map(\.name) == ["utf8mb4", "utf8mb3", "ascii", "latin1"])
        #expect(catalog.utf8Count == 2)
        #expect(catalog.charsets[0].title == "UTF-8 Unicode (utf8mb4)")
        #expect(catalog.charsets[2].title == "ascii")
    }

    @Test func collationsFollowTheCharacterSet() {
        #expect(catalog.collations(for: "latin1") == ["latin1_bin", "latin1_swedish_ci"])
        #expect(catalog.collations(for: nil) == ["utf8mb4_bin", "utf8mb4_general_ci", "utf8mb4_uca1400_ai_ci"])
        #expect(catalog.collations(for: "koi8r").isEmpty)
    }

    @Test func defaults() {
        #expect(catalog.defaultCollation(for: nil) == "utf8mb4_general_ci")
        #expect(catalog.defaultCollation(for: "utf8mb4") == "utf8mb4_uca1400_ai_ci")
        #expect(catalog.defaultCollation(for: "latin1") == "latin1_swedish_ci")
    }

    @Test func createStatement() {
        #expect(NewDatabase(name: "shop").sql == "CREATE DATABASE `shop`")
        #expect(NewDatabase(name: "a`b", charset: "latin1").sql == "CREATE DATABASE `a``b` CHARACTER SET `latin1`")
        #expect(NewDatabase(name: "shop", charset: "utf8mb4", collation: "utf8mb4_bin").sql
            == "CREATE DATABASE `shop` CHARACTER SET `utf8mb4` COLLATE `utf8mb4_bin`")
        #expect(NewDatabase(name: "shop", collation: "utf8mb4_bin").sql == "CREATE DATABASE `shop` COLLATE `utf8mb4_bin`")
    }

    @Test func nameProblems() {
        let existing = ["quarry_demo", "Shop"]
        #expect(NewDatabase.problem(with: "", existing: existing) == nil)
        #expect(NewDatabase.problem(with: "new_db", existing: existing) == nil)
        #expect(NewDatabase.problem(with: "shop", existing: existing) == "A database named “shop” already exists.")
        #expect(NewDatabase.problem(with: "   ", existing: existing) != nil)
        #expect(NewDatabase.problem(with: "trailing ", existing: existing) != nil)
        #expect(NewDatabase.problem(with: String(repeating: "x", count: 65), existing: existing) != nil)
        #expect(NewDatabase.problem(with: String(repeating: "x", count: 64), existing: existing) == nil)
    }
}
