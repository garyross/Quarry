import Foundation
import Testing
@testable import QuarryKit

@Suite("Views and routines: create, replace, names, parsing")
struct ObjectDefinitionTests {
    private let view = ViewDefinition(name: "big_orders", select: "SELECT * FROM orders WHERE total > 100;\n")

    @Test func viewLeavesDefaultsOut() {
        #expect(DefinitionChange.createSQL(view, in: "shop")
                == "CREATE VIEW `shop`.`big_orders` AS\nSELECT * FROM orders WHERE total > 100")
    }

    @Test func viewOptions() {
        var options = view
        options.algorithm = .merge
        options.security = .invoker
        options.checkOption = .cascaded
        #expect(DefinitionChange.createSQL(options, in: "shop", orReplace: true)
                == "CREATE OR REPLACE ALGORITHM=MERGE SQL SECURITY INVOKER VIEW `shop`.`big_orders` AS\n"
                + "SELECT * FROM orders WHERE total > 100\nWITH CASCADED CHECK OPTION")
    }

    @Test func viewEditReplacesOrRenames() {
        var edited = view
        edited.select = "SELECT 1"
        let same = DefinitionChange.plan(edited, replacing: view, in: "shop")
        #expect(same.drop == nil && same.cleanup == nil && same.create.hasPrefix("CREATE OR REPLACE VIEW"))
        edited.name = "orders_1"
        let renamed = DefinitionChange.plan(edited, replacing: view, in: "shop")
        #expect(renamed.create.hasPrefix("CREATE VIEW `shop`.`orders_1`"))
        #expect(renamed.cleanup == "DROP VIEW `shop`.`big_orders`")
        #expect(renamed.drop == nil)
    }

    @Test func procedure() {
        let routine = RoutineDefinition(kind: .procedure, name: "touch", parameters: " IN id INT ",
                                        body: "BEGIN\n  SELECT id;\nEND;")
        #expect(DefinitionChange.createSQL(routine, in: "shop")
                == "CREATE PROCEDURE `shop`.`touch`(IN id INT)\nBEGIN\n  SELECT id;\nEND")
    }

    @Test func functionWithCharacteristics() {
        let routine = RoutineDefinition(kind: .function, name: "tax", parameters: "amount DECIMAL(10,2)",
                                        returns: "DECIMAL(10,2)", deterministic: true, dataAccess: .noSQL,
                                        security: .invoker, comment: "It's 20%", body: "RETURN amount * 0.2")
        #expect(DefinitionChange.createSQL(routine, in: "shop")
                == "CREATE FUNCTION `shop`.`tax`(amount DECIMAL(10,2)) RETURNS DECIMAL(10,2)\n"
                + "DETERMINISTIC NO SQL SQL SECURITY INVOKER COMMENT 'It\\'s 20%'\nRETURN amount * 0.2")
    }

    @Test func routineEditDropsCreatesAndRestores() {
        let original = RoutineDefinition(kind: .procedure, name: "p", body: "SELECT 1")
        var edited = original
        edited.name = "q"
        let plan = DefinitionChange.plan(edited, replacing: original, originalStatement: "CREATE DEFINER=`a`@`%` PROCEDURE `p`() SELECT 1",
                                         in: "shop")
        #expect(plan.drop == "DROP PROCEDURE `shop`.`p`")
        #expect(plan.create == "CREATE PROCEDURE `shop`.`q`()\nSELECT 1")
        #expect(plan.restore == ["CREATE DEFINER=`a`@`%` PROCEDURE `p`() SELECT 1", "CREATE PROCEDURE `shop`.`p`()\nSELECT 1"])
        let new = DefinitionChange.plan(edited, replacing: nil, in: "shop")
        #expect(new.drop == nil && new.restore.isEmpty)
    }

    @Test func namesShareSpacesByKind() {
        let existing = [DBObject(name: "orders", kind: .table), DBObject(name: "total", kind: .procedure),
                        DBObject(name: "tax", kind: .function)]
        #expect(DefinitionChange.nameProblem("Orders", kind: .view, existing: existing, original: nil)
                == "A table or view named “Orders” already exists.")
        #expect(DefinitionChange.nameProblem("orders", kind: .procedure, existing: existing, original: nil) == nil)
        #expect(DefinitionChange.nameProblem("tax", kind: .procedure, existing: existing, original: nil) == nil)
        #expect(DefinitionChange.nameProblem("total", kind: .procedure, existing: existing, original: nil)
                == "A procedure named “total” already exists.")
        #expect(DefinitionChange.nameProblem("total", kind: .procedure, existing: existing, original: "total") == nil)
        #expect(DefinitionChange.nameProblem("", kind: .function, existing: existing, original: nil) == nil)
    }

    @Test func parametersFromShowCreate() {
        let procedure = "CREATE DEFINER=`root`@`localhost` PROCEDURE `order_count`(IN customer INT, OUT n DECIMAL(10,2))\nBEGIN\nEND"
        #expect(DefinitionChange.parameters(inCreate: procedure, kind: .procedure) == "IN customer INT, OUT n DECIMAL(10,2)")
        let function = "CREATE DEFINER=`proc(edure)`@`%` FUNCTION `f`(s VARCHAR(10) CHARSET utf8mb4, c CHAR(1) DEFAULT ')') RETURNS int(11)\nRETURN 1"
        #expect(DefinitionChange.parameters(inCreate: function, kind: .function) == "s VARCHAR(10) CHARSET utf8mb4, c CHAR(1) DEFAULT ')'")
        #expect(DefinitionChange.parameters(inCreate: "CREATE PROCEDURE `p`()\nSELECT 1", kind: .procedure) == "")
    }

    @Test func algorithmFromShowCreate() {
        #expect(DefinitionChange.algorithm(inCreate: "CREATE ALGORITHM=MERGE DEFINER=`a`@`%` SQL SECURITY DEFINER VIEW `v` AS select 1") == .merge)
        #expect(DefinitionChange.algorithm(inCreate: "CREATE VIEW `v` AS select 1") == .undefined)
    }
}
