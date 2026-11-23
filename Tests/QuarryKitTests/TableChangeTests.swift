import Foundation
import Testing
@testable import QuarryKit

/// `TableChange.plan` gives exactly the SQL each controller built itself before
/// the change paths were joined: MySQL's builders, SQLite's index SQL, and
/// `SQLiteTableChange` plans.
@Suite struct TableChangeTests {
    private let id = FieldDefinition(name: "id", type: "int", isNullable: false)
    private let name = FieldDefinition(name: "name", type: "varchar", length: "20", isNullable: false)
    private let index = IndexDefinition(kind: .unique, name: "u_name", parts: [IndexPart(field: "name")])
    private let key = ForeignKeyDefinition(name: "fk_c", field: "id", referencedTable: "customers", referencedField: "id")

    private var mysql: TableShape {
        TableShape(table: "t", database: "shop", engine: .mysql, fields: [id, name], foreignKeys: ["fk_a", "fk_b"])
    }

    private func sqlite() throws -> TableShape {
        let create = try #require(SQLiteTable(sql: """
            CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL,
              FOREIGN KEY (id) REFERENCES a (id), FOREIGN KEY (name) REFERENCES b (name))
            """))
        let fields = [FieldDefinition(name: "id", type: "integer", isNullable: true),
                      FieldDefinition(name: "name", type: "text", isNullable: false)]
        return TableShape(table: "t", database: "main", engine: .sqlite, fields: fields,
                          foreignKeys: ["t_fk_1", "t_fk_2"], sqlite: create)
    }

    @Test func mysqlIsTheOldStatements() throws {
        var renamed = name
        renamed.name = "title"
        let expected: [(TableChange, String)] = [
            (.editField("name", renamed, .first), FieldChange.changeSQL("name", to: renamed, in: "t", database: "shop", position: .first)),
            (.addField(renamed, .after("id")), FieldChange.addSQL(renamed, to: "t", in: "shop", position: .after("id"))),
            (.duplicateField("name"), FieldChange.addSQL(FieldChange.duplicate(name, existing: ["id", "name"]), to: "t", in: "shop",
                                                         position: .after("name"))),
            (.dropFields(["id", "name"]), FieldChange.dropSQL(["id", "name"], from: "t", in: "shop")),
            (.addIndex(index), IndexChange.addSQL(index, to: "t", in: "shop")),
            (.dropIndexes(["u_name"]), IndexChange.dropSQL(["u_name"], from: "t", in: "shop")),
            (.addForeignKey(key), ForeignKeyChange.addSQL(key, to: "t", in: "shop")),
            (.dropForeignKeys(["fk_b"]), ForeignKeyChange.dropSQL(["fk_b"], from: "t", in: "shop")),
        ]
        for (change, sql) in expected {
            let plan = try change.plan(mysql)
            #expect(plan == .statements([sql]))
            #expect(!plan.needsRebuild && !plan.isEmpty && plan.summary == sql)
        }
    }

    @Test func sqliteIndexesAreStatements() throws {
        let shape = try sqlite()
        #expect(try TableChange.addIndex(index).plan(shape) == .statements([IndexChange.sqliteAddSQL(index, to: "t")]))
        #expect(try TableChange.dropIndexes(["u_name"]).plan(shape) == .statements(IndexChange.sqliteDropSQL(["u_name"])))
    }

    @Test func sqliteFieldsAndKeysAreTheOldPlans() throws {
        let shape = try sqlite()
        let create = try #require(shape.sqlite)
        func old(_ change: SQLiteTableChange) throws -> TableChangePlan {
            .sqlite(try change.plan(table: "t", create: create, fields: shape.fields))
        }
        var renamed = shape.fields[1]
        renamed.name = "title"
        #expect(try TableChange.editField("name", renamed, .unchanged).plan(shape) == old(.edit("name", renamed, .unchanged)))
        #expect(try TableChange.addField(renamed, .after("id")).plan(shape) == old(.add(renamed, .after("id"))))
        #expect(try TableChange.dropFields(["name"]).plan(shape) == old(.drop(["name"])))
        #expect(try TableChange.addForeignKey(key).plan(shape) == old(.addForeignKey(key)))
        // Keys by name become PRAGMA foreign_key_list ids, their places in the list.
        #expect(try TableChange.dropForeignKeys(["t_fk_2"]).plan(shape) == old(.dropForeignKeys([1])))
        // A NOT NULL field with no default is copied as nullable, since the copy starts empty.
        var copy = FieldChange.duplicate(shape.fields[1], existing: ["id", "name"])
        copy.isNullable = true
        copy.defaultValue = .null
        #expect(try TableChange.duplicateField("name").plan(shape) == old(.add(copy, .after("name"))))
    }

    @Test func sqliteNeedsItsCreateTable() throws {
        var shape = try sqlite()
        shape.sqlite = nil
        #expect(throws: DatabaseError.self) { try TableChange.dropFields(["name"]).plan(shape) }
        #expect(try TableChange.duplicateField("missing").plan(mysql).isEmpty)
    }
}
