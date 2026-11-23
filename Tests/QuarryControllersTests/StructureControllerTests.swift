import Foundation
import Testing
import QuarryKit
import QuarryControllers

/// Structure (S-023, S-024, S-070) through StructureController's interface, on a
/// copy of the SQLite fixture. A change SQLite's ALTER TABLE can't make rebuilds the table.
@Suite struct StructureControllerTests {
    static func showing(_ table: String, readOnly: Bool = false) async throws -> (StructureController, DatabaseClient) {
        let client = try await Fixture.sqlite(readOnly: readOnly)
        let structure = StructureController()
        let object = try await Fixture.object(table, client: client)
        await structure.show(object, in: "main", client: client, force: false)?.value
        #expect(structure.load.error == nil)
        return (structure, client)
    }

    static func gridColumn(_ column: StructureController.Column, _ structure: StructureController) throws -> Int {
        try #require(structure.columns.firstIndex(of: column))
    }

    static func fieldNames(_ table: String, _ client: DatabaseClient) async throws -> [String] {
        try await client.fields(of: table, in: "main").map(\.name)
    }

    @Test func showsFieldsAndIndexes() async throws {
        let (structure, _) = try await Self.showing("orders")
        #expect(structure.names == ["id", "customer_id", "placed_at", "status", "note"])
        #expect(structure.fields.rows.count == 5)
        #expect(Set(structure.indexSummaries.map(\.name)).isSuperset(of: ["orders_customer", "orders_status_placed"]))
        // SQLite has no Length, Unsigned or Comment.
        #expect(!structure.columns.contains(.unsigned) && !structure.columns.contains(.comment))
        #expect(structure.canEdit && structure.canAddField)
    }

    @Test func addFieldAddsItAtTheEnd() async throws {
        let (structure, client) = try await Self.showing("customers")
        structure.requestAddField()
        let sheet = try #require(structure.fieldSheet)
        #expect(sheet.isSQLite && sheet.type == "text")
        sheet.name = "nickname"
        #expect(sheet.canSave)
        await structure.saveSheet()?.value
        #expect(structure.editError == nil && sheet.error == nil)
        #expect(structure.fieldSheet == nil)
        #expect(structure.names.last == "nickname")
        #expect(try await Self.fieldNames("customers", client).last == "nickname")
    }

    @Test func renameInlineKeepsTheRows() async throws {
        let (structure, client) = try await Self.showing("customers")
        let name = try Self.gridColumn(.name, structure)
        let row = try #require(structure.names.firstIndex(of: "country"))
        #expect(structure.canEdit(row: row, column: name))
        await structure.edit(row: row, column: name, to: .text("nation"))?.value
        #expect(structure.editError == nil)
        #expect(structure.names.contains("nation") && !structure.names.contains("country"))
        #expect(try await Fixture.strings("SELECT nation FROM customers WHERE id = 1", client: client) == ["UK"])
    }

    @Test func changingADefaultRebuildsTheTableAndKeepsItsRows() async throws {
        let (structure, client) = try await Self.showing("orders")
        let row = try #require(structure.names.firstIndex(of: "status"))
        await structure.edit(row: row, column: try Self.gridColumn(.defaultValue, structure), to: .text("open"))?.value
        #expect(structure.editError == nil)
        #expect(structure.definitions[row].defaultValue.text == "open")
        #expect(try await Fixture.strings("SELECT COUNT(*) FROM orders", client: client) == ["5"])
        // The indexes came back after the rebuild.
        #expect(Set(structure.indexSummaries.map(\.name)).isSuperset(of: ["orders_customer", "orders_status_placed"]))
    }

    @Test func moveFieldChangesTheOrder() async throws {
        let (structure, client) = try await Self.showing("orders")
        structure.selection = [4]
        #expect(structure.canMove(by: -1) && !structure.canMove(by: 1))
        await structure.moveSelected(by: -1)?.value
        #expect(structure.editError == nil)
        #expect(structure.names == ["id", "customer_id", "placed_at", "note", "status"])
        #expect(try await Self.fieldNames("orders", client) == ["id", "customer_id", "placed_at", "note", "status"])
    }

    @Test func deleteFieldsAsksThenDrops() async throws {
        let (structure, client) = try await Self.showing("orders")
        structure.selection = [4]
        #expect(structure.canDeleteFields)
        structure.requestDeleteFields()
        #expect(structure.pendingDelete == ["note"])
        await structure.confirmDeleteFields()?.value
        #expect(structure.editError == nil)
        #expect(try await Self.fieldNames("orders", client) == ["id", "customer_id", "placed_at", "status"])
    }

    @Test func everyFieldCantBeDeleted() async throws {
        let (structure, _) = try await Self.showing("notes")
        structure.selection = [0]
        #expect(!structure.canDeleteFields)
    }

    @Test func addAndDeleteAnIndex() async throws {
        let (structure, client) = try await Self.showing("customers")
        #expect(structure.canAddIndex)
        structure.requestAddIndex()
        let sheet = try #require(structure.indexSheet)
        sheet.name = "customers_country"
        sheet.parts = [IndexDraft.Part(field: "country")]
        await structure.saveIndexSheet()?.value
        #expect(structure.editError == nil && sheet.error == nil)
        #expect(structure.indexSummaries.contains { $0.name == "customers_country" })

        let row = try #require(structure.indexRowNames.firstIndex(of: "customers_country"))
        structure.indexSelection = [row]
        structure.requestDeleteIndexes()
        await structure.confirmDeleteIndexes()?.value
        #expect(!structure.indexSummaries.contains { $0.name == "customers_country" })
        let indexes = try await client.indexes(of: "customers", in: "main")
        #expect(!indexes.rows.indices.contains { indexes.string($0, "Key_name") == "customers_country" })
    }

    @Test func aReadOnlyFileOrAViewCantChange() async throws {
        let (readOnly, _) = try await Self.showing("customers", readOnly: true)
        #expect(!readOnly.canEdit && !readOnly.canAddField && !readOnly.canAddIndex)
        let (view, _) = try await Self.showing("order_totals")
        #expect(!view.canEdit)
    }
}

/// Foreign Keys and Triggers (S-025, S-026, S-070) on a SQLite file.
@Suite struct ForeignKeysAndTriggersTests {
    @Test func deleteAndAddAForeignKey() async throws {
        let client = try await Fixture.sqlite()
        let keys = ForeignKeysController()
        let object = try await Fixture.object("order_items", client: client)
        await keys.show(object, in: "main", client: client, force: false)?.value
        #expect(keys.isSQLite && keys.supportsKeys)
        #expect(keys.keys.count == 2)

        let products = try #require(keys.keys.firstIndex { $0.referencedTable == "products" })
        keys.selection = [products]
        keys.requestDelete()
        await keys.confirmDelete()?.value
        #expect(keys.editError == nil)
        #expect(keys.keys.map(\.referencedTable) == ["orders"])

        await keys.requestAdd()?.value
        let sheet = try #require(keys.sheet)
        sheet.field = "product_id"
        sheet.referencedTable = "products"
        await keys.referencedTableChanged()?.value
        sheet.referencedField = "id"
        #expect(sheet.canSave)
        await keys.saveSheet()?.value
        #expect(keys.editError == nil && sheet.error == nil)
        #expect(Set(keys.keys.map(\.referencedTable)) == ["orders", "products"])
        #expect(try await Fixture.strings("SELECT COUNT(*) FROM order_items", client: client) == ["7"])
    }

    @Test func addEditAndDeleteATrigger() async throws {
        let client = try await Fixture.sqlite()
        let triggers = TriggersController()
        let object = try await Fixture.object("customers", client: client)
        await triggers.show(object, in: "main", client: client, force: false)?.value
        #expect(triggers.triggers.isEmpty && triggers.canAdd)

        await triggers.requestSheet(editing: nil)?.value
        let sheet = try #require(triggers.sheet)
        #expect(sheet.isSQLite && !sheet.isEdit)
        sheet.timing = .after
        sheet.event = .insert
        sheet.statement = "UPDATE customers SET country = 'NL' WHERE id = NEW.id;"
        await triggers.saveSheet()?.value
        #expect(sheet.error == nil && triggers.sheet == nil)
        #expect(triggers.triggers.count == 1)

        _ = try await client.run("INSERT INTO customers (name) VALUES ('Trigger Test')")
        #expect(try await Fixture.strings("SELECT country FROM customers WHERE name = 'Trigger Test'", client: client) == ["NL"])

        triggers.selection = [0]
        #expect(triggers.canDelete)
        triggers.requestDelete()
        await triggers.confirmDelete()?.value
        #expect(triggers.editError == nil && triggers.triggers.isEmpty)
    }
}

/// What the field sheet offers on each engine (S-023, S-070).
@Suite struct FieldDraftTests {
    @Test func sqliteOffersAnyDefaultAndAutoIncrementOnlyOnTheRowIDKey() async throws {
        let client = try await Fixture.sqlite()
        let structure = StructureController()
        await structure.show(try await Fixture.object("customers", client: client), in: "main", client: client, force: false)?.value

        structure.requestEditField(row: 0)
        let id = try #require(structure.fieldSheet)
        #expect(id.extras == [.none, .autoIncrement])
        #expect(id.extraTitle(.autoIncrement) == "AUTOINCREMENT")

        let row: Int = try #require(structure.names.firstIndex(of: "name"))
        structure.requestEditField(row: row)
        let name = try #require(structure.fieldSheet)
        #expect(name.extras == [.none])
        // NOT NULL: no NULL default, but any other kind, on any type.
        #expect(name.defaultKinds == [.none, .currentTimestamp, .value])
        #expect(name.sqliteTypes == ["INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC"])
    }

    @Test func aNameTheTableHasIsAProblem() async throws {
        let client = try await Fixture.sqlite()
        let structure = StructureController()
        await structure.show(try await Fixture.object("customers", client: client), in: "main", client: client, force: false)?.value
        structure.requestAddField()
        let sheet = try #require(structure.fieldSheet)
        sheet.name = "Email"
        #expect(sheet.nameProblem == "The table already has a field named “Email”.")
        #expect(!sheet.canSave)
    }
}
