import Foundation
import Testing
@testable import QuarryKit

@Suite("Foreign keys for ALTER TABLE")
struct ForeignKeyDefinitionTests {
    private func field(_ name: String, _ type: String, length: String = "", unsigned: Bool = false,
                       collation: String? = nil) -> FieldDefinition {
        FieldDefinition(name: name, type: type, length: length, isUnsigned: unsigned, collation: collation)
    }

    @Test func addWithNameAndActions() {
        let key = ForeignKeyDefinition(name: "fk_orders_customer", field: "customer_id", referencedTable: "customers",
                                       referencedField: "id", onUpdate: .cascade, onDelete: .setNull)
        #expect(ForeignKeyChange.addSQL(key, to: "orders", in: "shop")
                == "ALTER TABLE `shop`.`orders` ADD CONSTRAINT `fk_orders_customer` FOREIGN KEY (`customer_id`) "
                + "REFERENCES `shop`.`customers` (`id`) ON DELETE SET NULL ON UPDATE CASCADE")
    }

    @Test func addWithoutName() {
        let key = ForeignKeyDefinition(name: "  ", field: "a", referencedTable: "t", referencedField: "b")
        #expect(ForeignKeyChange.addSQL(key, to: "u", in: "d")
                == "ALTER TABLE `d`.`u` ADD FOREIGN KEY (`a`) REFERENCES `d`.`t` (`b`) ON DELETE RESTRICT ON UPDATE RESTRICT")
    }

    @Test func dropSeveralInOneStatement() {
        #expect(ForeignKeyChange.dropSQL(["fk_a", "fk_b"], from: "t", in: "d")
                == "ALTER TABLE `d`.`t` DROP FOREIGN KEY `fk_a`, DROP FOREIGN KEY `fk_b`")
    }

    @Test func names() {
        #expect(ForeignKeyChange.nameProblem("", existing: ["fk_a"]) == nil)
        #expect(ForeignKeyChange.nameProblem("FK_A", existing: ["fk_a"]) == "A foreign key named “FK_A” already exists.")
        #expect(ForeignKeyChange.nameProblem(String(repeating: "x", count: 65), existing: []) != nil)
    }

    @Test func integersNeedTheSameTypeAndSign() {
        let id = field("id", "int", length: "10", unsigned: true)
        #expect(ForeignKeyChange.isCompatible(field("c", "int", length: "11", unsigned: true), with: id))
        #expect(!ForeignKeyChange.isCompatible(field("c", "int"), with: id))
        #expect(!ForeignKeyChange.isCompatible(field("c", "bigint", unsigned: true), with: id))
    }

    @Test func stringsNeedTheSameCollation() {
        let code = field("code", "varchar", length: "32", collation: "utf8mb4_general_ci")
        #expect(ForeignKeyChange.isCompatible(field("c", "char", length: "2", collation: "utf8mb4_general_ci"), with: code))
        #expect(!ForeignKeyChange.isCompatible(field("c", "varchar", length: "32", collation: "latin1_swedish_ci"), with: code))
        #expect(!ForeignKeyChange.isCompatible(field("c", "text"), with: field("t", "text")))
    }

    @Test func decimalsAndDates() {
        #expect(ForeignKeyChange.isCompatible(field("a", "decimal", length: "10"), with: field("b", "decimal", length: "10,0")))
        #expect(!ForeignKeyChange.isCompatible(field("a", "decimal", length: "10,2"), with: field("b", "decimal", length: "12,2")))
        #expect(ForeignKeyChange.isCompatible(field("a", "date"), with: field("b", "date")))
        #expect(!ForeignKeyChange.isCompatible(field("a", "date"), with: field("b", "datetime")))
    }

    @Test func onlyFieldsLeadingAnIndex() {
        let fields = [field("id", "int", unsigned: true), field("other_id", "int", unsigned: true),
                      field("second", "int", unsigned: true), field("name", "varchar", length: "50")]
        let indexes = [IndexSummary(name: "PRIMARY", fields: ["id"]), IndexSummary(name: "pair", fields: ["other_id", "second"])]
        #expect(ForeignKeyChange.referenceable(from: field("x", "int", unsigned: true), among: fields, indexes: indexes)
                == ["id", "other_id"])
    }

    @Test func guessesTheTableFromTheName() {
        let tables = ["categories", "customers", "orders", "box"]
        #expect(ForeignKeyChange.guessTable(for: "customer_id", among: tables) == "customers")
        #expect(ForeignKeyChange.guessTable(for: "category_id", among: tables) == "categories")
        #expect(ForeignKeyChange.guessTable(for: "box_id", among: tables) == "box")
        #expect(ForeignKeyChange.guessTable(for: "price", among: tables) == nil)
    }

    @Test func readsInnoDBStatus() {
        let status = """
            ------------------------
            LATEST FOREIGN KEY ERROR
            ------------------------
            2026-11-18 10:12:01 0x16f2b3000 Error in foreign key constraint of table `d`.`t`:
            FOREIGN KEY (`a`) REFERENCES `u` (`b`):
            Cannot find an index in the referenced table.
            ------------
            TRANSACTIONS
            """
        #expect(InnoDBStatus.latestForeignKeyError(status)
                == "Error in foreign key constraint of table `d`.`t`: FOREIGN KEY (`a`) REFERENCES `u` (`b`): "
                + "Cannot find an index in the referenced table.")
        #expect(InnoDBStatus.latestForeignKeyError("nothing here") == nil)
    }
}
