import Foundation
import Testing
@testable import QuarryKit

@Suite("Triggers: create, replace, names")
struct TriggerDefinitionTests {
    private let trigger = TriggerDefinition(name: "orders_before_update", timing: .before, event: .update,
                                            statement: "  SET NEW.total = 0;\n\n")

    @Test func createDropsTheFinalSemicolon() {
        #expect(TriggerChange.createSQL(trigger, on: "orders", in: "shop", engine: .mysql)
                == "CREATE TRIGGER `shop`.`orders_before_update` BEFORE UPDATE ON `shop`.`orders` FOR EACH ROW\nSET NEW.total = 0")
    }

    @Test func blockKeepsItsInnerSemicolons() {
        let block = TriggerDefinition(name: "t", statement: "BEGIN\n  SET NEW.a = 1;\nEND;")
        #expect(block.trimmedStatement == "BEGIN\n  SET NEW.a = 1;\nEND")
    }

    @Test func dropIsQualified() {
        #expect(TriggerChange.dropSQL("a`b", in: "shop") == "DROP TRIGGER `shop`.`a``b`")
    }

    @Test func editDropsCreatesAndCanRestore() {
        var edited = trigger
        edited.name = "orders_after_update"
        edited.timing = .after
        let plan = TriggerChange.plan(edited, replacing: trigger, on: "orders", in: "shop", engine: .mysql)
        #expect(plan.drop == "DROP TRIGGER `shop`.`orders_before_update`")
        #expect(plan.create.hasPrefix("CREATE TRIGGER `shop`.`orders_after_update` AFTER UPDATE"))
        #expect(plan.restore == TriggerChange.createSQL(trigger, on: "orders", in: "shop", engine: .mysql))
    }

    @Test func addHasNothingToRestore() {
        let plan = TriggerChange.plan(trigger, replacing: nil, on: "orders", in: "shop", engine: .mysql)
        #expect(plan.drop == nil && plan.restore == nil)
    }

    @Test func namesAreUniqueIgnoringCase() {
        let taken = ["orders_before_update", "other"]
        #expect(TriggerChange.nameProblem("OTHER", taken: taken, original: nil) != nil)
        #expect(TriggerChange.nameProblem("Orders_Before_Update", taken: taken, original: "orders_before_update") == nil)
        #expect(TriggerChange.nameProblem("", taken: taken, original: nil) == nil)
        #expect(TriggerChange.nameProblem(String(repeating: "x", count: 65), taken: [], original: nil) != nil)
    }

    @Test func suggestedNameCounts() {
        #expect(TriggerChange.suggestedName(table: "orders", timing: .after, event: .delete, taken: [])
                == "orders_after_delete")
        #expect(TriggerChange.suggestedName(table: "orders", timing: .before, event: .update,
                                            taken: ["orders_before_update", "orders_before_update_2"])
                == "orders_before_update_3")
    }

    @Test func readsShowTriggers() {
        let columns = ["Trigger", "Event", "Table", "Statement", "Timing"].map { ResultColumn(name: $0) }
        let result = StatementResult(sql: "", columns: columns, rows: [
            [.text("t1"), .text("UPDATE"), .text("orders"), .text("SET NEW.a = 1\0"), .text("BEFORE")],
            [.text("odd"), .text("TRUNCATE"), .text("orders"), .text(""), .text("BEFORE")],
        ], affectedRows: nil, duration: .zero)
        #expect(TriggerDefinition.list(from: result)
                == [TriggerDefinition(name: "t1", timing: .before, event: .update, statement: "SET NEW.a = 1")])
    }
}
