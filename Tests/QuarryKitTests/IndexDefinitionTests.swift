import Foundation
import Testing
@testable import QuarryKit

@Suite("Indexes for ALTER TABLE")
struct IndexDefinitionTests {
    @Test func plainIndexWithPrefixes() {
        let index = IndexDefinition(kind: .index, name: "idx_name_email",
                                    parts: [IndexPart(field: "name", prefix: 10), IndexPart(field: "email")])
        #expect(IndexChange.addSQL(index, to: "customers", in: "shop")
                == "ALTER TABLE `shop`.`customers` ADD INDEX `idx_name_email` (`name`(10), `email`)")
    }

    @Test func storageAndKeyBlockSize() {
        let index = IndexDefinition(kind: .unique, name: "", parts: [IndexPart(field: "email")], storage: .btree,
                                    keyBlockSize: 8, comment: "One per person")
        #expect(IndexChange.addSQL(index, to: "customers", in: "shop")
                == "ALTER TABLE `shop`.`customers` ADD UNIQUE INDEX USING BTREE (`email`) KEY_BLOCK_SIZE = 8 COMMENT 'One per person'")
        let hash = IndexDefinition(kind: .index, name: "h", parts: [IndexPart(field: "id")], storage: .hash)
        #expect(IndexChange.addSQL(hash, to: "t", in: "d") == "ALTER TABLE `d`.`t` ADD INDEX `h` USING HASH (`id`)")
    }

    @Test func primaryKeyHasNoName() {
        let index = IndexDefinition(kind: .primary, name: "ignored", parts: [IndexPart(field: "a"), IndexPart(field: "b")])
        #expect(IndexChange.addSQL(index, to: "t", in: "d") == "ALTER TABLE `d`.`t` ADD PRIMARY KEY (`a`, `b`)")
    }

    @Test func fullTextDropsPrefixAndStorage() {
        let index = IndexDefinition(kind: .fullText, name: "ft", parts: [IndexPart(field: "body", prefix: 20)],
                                    storage: .btree)
        #expect(IndexChange.addSQL(index, to: "t", in: "d") == "ALTER TABLE `d`.`t` ADD FULLTEXT INDEX `ft` (`body`)")
        let spatial = IndexDefinition(kind: .spatial, parts: [IndexPart(field: "place")])
        #expect(IndexChange.addSQL(spatial, to: "t", in: "d") == "ALTER TABLE `d`.`t` ADD SPATIAL INDEX (`place`)")
    }

    @Test func prefixRules() {
        #expect(PrefixRule.of(type: "text", kind: .index) == .required)
        #expect(PrefixRule.of(type: "longblob", kind: .unique) == .required)
        #expect(PrefixRule.of(type: "varchar", kind: .index) == .optional)
        #expect(PrefixRule.of(type: "varbinary", kind: .primary) == .optional)
        #expect(PrefixRule.of(type: "int", kind: .index) == .none)
        #expect(PrefixRule.of(type: "text", kind: .fullText) == .none)
    }

    @Test func dropInOneStatement() {
        #expect(IndexChange.dropSQL(["PRIMARY", "idx_email"], from: "t", in: "d")
                == "ALTER TABLE `d`.`t` DROP PRIMARY KEY, DROP INDEX `idx_email`")
    }

    @Test func names() {
        #expect(IndexChange.nameProblem("", existing: ["a"]) == nil)
        #expect(IndexChange.nameProblem("IDX_Email", existing: ["idx_email"]) == "An index named \u{201C}IDX_Email\u{201D} already exists.")
        #expect(IndexChange.nameProblem("primary", existing: []) != nil)
        #expect(IndexChange.nameProblem(String(repeating: "x", count: 65), existing: []) != nil)
    }

    @Test func groupsShowIndexRows() {
        let groups = IndexSummary.group(names: ["PRIMARY", "idx", "idx", "email"], fields: ["id", "a", "b", "email"])
        #expect(groups == [IndexSummary(name: "PRIMARY", fields: ["id"]), IndexSummary(name: "idx", fields: ["a", "b"]),
                           IndexSummary(name: "email", fields: ["email"])])
        #expect(groups[0].isPrimary)
    }
}
