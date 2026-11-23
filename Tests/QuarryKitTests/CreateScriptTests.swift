import Foundation
import Testing
@testable import QuarryKit

@Suite("Create statement text")
struct CreateScriptTests {
    let table = CreateScript.Item(object: DBObject(name: "orders", kind: .table),
                                  statement: "CREATE TABLE `orders` (\n  `id` int NOT NULL\n) ENGINE=InnoDB")
    let procedure = CreateScript.Item(object: DBObject(name: "refresh", kind: .procedure),
                                      statement: "CREATE PROCEDURE `refresh`()\nBEGIN\n  SELECT 1;\nEND")

    @Test func oneTableEndsWithASemicolonAndNoHeader() {
        #expect(CreateScript.text([table]) == table.statement + ";")
    }

    @Test func aStatementThatEndsInASemicolonGetsOnlyOne() {
        let item = CreateScript.Item(object: table.object, statement: table.statement + ";\n")
        #expect(CreateScript.text([item]) == table.statement + ";")
    }

    @Test func aRoutineSitsBetweenDelimiters() {
        #expect(CreateScript.text([procedure]) == "DELIMITER ;;\n\(procedure.statement);;\nDELIMITER ;")
    }

    @Test func severalObjectsEachGetAHeader() {
        let text = CreateScript.text([table, procedure])
        #expect(text.hasPrefix("-- Create statement for table `orders`\nCREATE TABLE `orders`"))
        #expect(text.contains(";\n\n-- Create statement for procedure `refresh`\nDELIMITER ;;\n"))
    }

    @Test func theFileIsNamedForTheObjectOrTheDatabase() {
        #expect(CreateScript.fileName([table], database: "shop") == "orders.sql")
        #expect(CreateScript.fileName([table, procedure], database: "shop") == "shop.sql")
        let odd = CreateScript.Item(object: DBObject(name: "a/b:c", kind: .view), statement: "")
        #expect(CreateScript.fileName([odd], database: "shop") == "a-b-c.sql")
    }
}
