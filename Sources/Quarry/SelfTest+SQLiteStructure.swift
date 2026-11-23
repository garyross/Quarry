import AppKit
import QuarryKit
import QuarryControllers

/// S-070: changing a SQLite table's structure, on its own copy of the fixture.
extension SelfTest {
    static func sqliteStructure(_ tab: Session, model: AppModel) async {
        guard let url = makeSQLiteFixture(named: "quarry_structure.sqlite") else { return check("S-070 a SQLite fixture to change", false) }
        await openSQLite(tab, url, model: model)
        guard tab.phase == .connected, let client = tab.client else { return check("S-070 the fixture opens", false) }
        await sqliteFields(tab, client)
        await sqliteRebuildAsks(tab, client)
        await sqliteIndexesAndKeys(tab, client)
        await sqliteTriggers(tab, client)
        await sqliteTablesAndViews(tab, client)
        tab.disconnect()
    }

    private static func create(_ client: DatabaseClient, _ table: String) async -> String {
        (try? await client.run("SELECT sql FROM sqlite_schema WHERE name = '\(table)'"))?.rows.first?.first?.plainText ?? ""
    }

    private static func value(_ client: DatabaseClient, _ sql: String) async -> String? {
        try? await client.run(sql).rows.first?.first?.plainText
    }

    private static func showStructure(_ tab: Session, _ table: String) async {
        tab.view = .structure
        tab.selectedObjectID = "table:\(table)"
        await tab.currentLoad?.value
        await until { tab.structure.load.loadedFor?.hasSuffix(table) == true }
    }

    // MARK: Fields

    private static func sqliteFields(_ tab: Session, _ client: DatabaseClient) async {
        let structure = tab.structure
        await showStructure(tab, "customers")
        check("S-070 Structure shows SQLite's columns, with no Length, Unsigned or Comment",
              structure.fields.columns.map(\.title) == ["Name", "Type", "Null", "Key", "Default", "Extra", "Collation"]
                  && structure.canEdit && structure.definitions.count == 5,
              structure.fields.columns.map(\.title).joined(separator: ", "))
        check("S-070 AUTOINCREMENT shows as the key's option", structure.fields.rows.first?[5] == .text("AUTOINCREMENT"))

        // Rename: ALTER TABLE … RENAME COLUMN, no rebuild.
        tab.editField(row: 3, column: 0, to: .text("nation"))
        await tab.currentLoad?.value
        let renamed = await create(client, "customers")
        check("S-070 renaming a field inline runs ALTER TABLE … RENAME COLUMN",
              structure.names == ["id", "name", "email", "nation", "created_at"] && structure.editError == nil
                  && renamed.contains("\"nation\" TEXT DEFAULT 'US'"),
              structure.editError?.message ?? renamed)

        // A type and a default change rebuild the table, keeping rows, its UNIQUE index and the sequence.
        let sequence = await value(client, "SELECT seq FROM sqlite_sequence WHERE name = 'customers'")
        tab.editField(row: 3, column: 1, to: .text("varchar(2)"))
        await tab.currentLoad?.value
        tab.editField(row: 3, column: 4, to: .text("GB"))
        await tab.currentLoad?.value
        let after = await create(client, "customers")
        check("S-070 a type or default change rebuilds the table",
              after.contains("\"nation\" VARCHAR(2) DEFAULT 'GB'") && structure.editError == nil
                  && structure.fields.rows[3][1] == .text("VARCHAR(2)"),
              structure.editError?.message ?? after)
        let kept = [await value(client, "SELECT count(*) FROM customers"),
                    await value(client, "SELECT count(*) FROM pragma_index_list('customers')"),
                    await value(client, "SELECT seq FROM sqlite_sequence WHERE name = 'customers'"),
                    await value(client, "SELECT nation FROM customers WHERE id = 1")]
        check("S-070 the rebuild keeps the rows, the UNIQUE index and the AUTOINCREMENT sequence",
              kept == ["6", "1", sequence, "UK"], kept.map { $0 ?? "nil" }.joined(separator: ", "))
        let children = [await value(client, "SELECT count(*) FROM orders"), await value(client, "SELECT count(*) FROM pragma_foreign_key_check")]
        check("S-070 rows that pointed at the table still do", children == ["5", "0"])

        // A failed rebuild: email has a NULL, so NOT NULL is refused and nothing changes.
        let before = await create(client, "customers")
        structure.selection = [2]
        structure.requestEditField()
        guard let sheet = structure.fieldSheet else { return check("S-070 Edit Field opens", false) }
        check("S-070 the sheet takes any type, with SQLite's to pick from, and no length",
              sheet.isSQLite && !sheet.isStrict && sheet.sqliteTypes == ["INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC"]
                  && sheet.extras == [.none])
        sheet.isNullable = false
        check("S-070 the sheet's footer says it rebuilds", sheet.sql.hasPrefix("Rebuilds the table:"),
              sheet.sql)
        tab.saveFieldSheet()
        await tab.currentLoad?.value
        await until { !structure.isChanging }
        let unchanged = await create(client, "customers")
        check("S-070 a rebuild that fails says why, names the table, and leaves it as it was",
              sheet.error?.message.contains("customers.email") == true && structure.fieldSheet === sheet && unchanged == before,
              sheet.error?.message ?? "no error")
        sheet.isNullable = true
        sheet.collation = "NOCASE"
        tab.saveFieldSheet()
        await tab.currentLoad?.value
        await until { structure.fieldSheet == nil }
        check("S-070 Save in the sheet rebuilds with the collation", structure.fields.rows[2][6] == .text("NOCASE"),
              structure.fieldSheet?.error?.message ?? "")

        // Move: a rebuild in the new order.
        structure.selection = [4]
        tab.moveField(by: -1)
        await tab.currentLoad?.value
        check("S-070 Move Field Up rebuilds in the new order",
              structure.names == ["id", "name", "email", "created_at", "nation"], structure.names.joined(separator: ", "))

        // Add at the end is ADD COLUMN; Add first is a rebuild; Delete is DROP COLUMN.
        structure.selection = [4]
        tab.requestAddField()
        guard let add = structure.fieldSheet else { return check("S-070 Add Field opens", false) }
        add.name = "vip"
        add.type = "INTEGER"
        add.defaultKind = .value
        add.defaultText = "0"
        check("S-070 adding at the end is ALTER TABLE … ADD COLUMN",
              add.sql == "ALTER TABLE \"customers\" ADD COLUMN \"vip\" INTEGER DEFAULT 0", add.sql)
        tab.saveFieldSheet()
        await tab.currentLoad?.value
        await until { structure.fieldSheet == nil }
        let vip = await value(client, "SELECT vip FROM customers LIMIT 1")
        check("S-070 Add Field adds it", structure.names.last == "vip" && vip == "0")
        structure.selection = [5]
        tab.requestDeleteFields()
        tab.confirmDeleteFields()
        await tab.currentLoad?.value
        check("S-070 Delete Field runs ALTER TABLE … DROP COLUMN", !structure.names.contains("vip") && structure.editError == nil,
              structure.editError?.message ?? "")
        structure.selection = [0]
        tab.duplicateField()
        await tab.currentLoad?.value
        let copied = await create(client, "customers")
        check("S-070 Duplicate Field adds a copy after it, without AUTOINCREMENT",
              structure.names.prefix(2) == ["id", "id_copy"] && !copied.contains("\"id_copy\" INTEGER PRIMARY"),
              structure.editError?.message ?? structure.names.joined(separator: ", "))
        structure.selection = [1]
        tab.requestDeleteFields()
        tab.confirmDeleteFields()
        await tab.currentLoad?.value

        // STRICT tables offer only their types.
        _ = try? await client.run("CREATE TABLE strict_things (id INTEGER PRIMARY KEY, label TEXT) STRICT")
        try? await tab.loadObjects(client, "main")
        await showStructure(tab, "strict_things")
        structure.selection = [1]
        structure.requestEditField()
        check("S-070 a STRICT table offers only its types", structure.fieldSheet?.isStrict == true
                  && structure.fieldSheet?.sqliteTypes == ["INT", "INTEGER", "REAL", "TEXT", "BLOB", "ANY"])
        structure.fieldSheet = nil
    }

    // MARK: Big tables ask

    private static func sqliteRebuildAsks(_ tab: Session, _ client: DatabaseClient) async {
        let structure = tab.structure
        await showStructure(tab, "events")
        let limit = StructureController.rebuildAskRows
        StructureController.rebuildAskRows = 1_000
        defer { StructureController.rebuildAskRows = limit }
        tab.editField(row: 3, column: 1, to: .text("numeric"))
        await tab.currentLoad?.value
        check("S-070 a rebuild of a big table asks first",
              structure.pendingRebuild?.rows == 2_500 && StructureController.rebuildTitle("events") == "Rebuild “events”?"
                  && StructureController.rebuildMessage(rows: 2_500)
                    == "SQLite changes this field by copying the table’s 2,500 rows into a new one. Nothing changes if it fails.",
              "\(structure.pendingRebuild?.rows ?? -1)")
        await sheetSettles(on: tab.window)
        structure.cancelRebuild()
        let events = await create(client, "events")
        check("S-070 Cancel leaves it as it was", events.contains("amount REAL"), events)
        tab.editField(row: 3, column: 1, to: .text("numeric"))
        await tab.currentLoad?.value
        await sheetSettles(on: tab.window)
        tab.confirmRebuild()
        await tab.currentLoad?.value
        let rebuilt = await create(client, "events")
        let rows = await value(client, "SELECT count(*) FROM events")
        check("S-070 Rebuild changes it, keeping every row", rebuilt.contains("\"amount\" NUMERIC") && rows == "2500",
              structure.editError?.message ?? rebuilt)
    }

    // MARK: Indexes and foreign keys

    private static func sqliteIndexesAndKeys(_ tab: Session, _ client: DatabaseClient) async {
        let structure = tab.structure
        await showStructure(tab, "orders")
        structure.selection = [4]
        tab.requestAddIndex()
        guard let index = structure.indexSheet else { return check("S-070 Add Index opens", false) }
        check("S-070 Add Index offers Index and Unique, as CREATE INDEX",
              index.kinds == [.index, .unique] && index.sql == "CREATE INDEX \"orders_note\" ON \"orders\" (\"note\")",
              index.sql)
        tab.saveIndexSheet()
        await tab.currentLoad?.value
        await until { structure.indexSheet == nil }
        check("S-070 Add Index makes it", structure.indexRowNames.contains("orders_note"), structure.indexRowNames.joined(separator: ", "))
        structure.indexSelection = IndexSet(structure.indexRowNames.indices.filter { structure.indexRowNames[$0] == "orders_note" })
        tab.requestDeleteIndexes()
        tab.confirmDeleteIndexes()
        await tab.currentLoad?.value
        check("S-070 Delete Index drops it", !structure.indexRowNames.contains("orders_note") && structure.editError == nil,
              structure.editError?.message ?? "")
        await showStructure(tab, "customers")
        structure.indexSelection = IndexSet(structure.indexRowNames.indices.filter { structure.indexRowNames[$0].hasPrefix("sqlite_autoindex") })
        check("S-070 the index of a UNIQUE field can't be deleted on its own", !structure.indexSelection.isEmpty && !structure.canDeleteIndexes)

        // Foreign keys: notes gets a field, then a key to customers (a rebuild), then loses it.
        await showStructure(tab, "notes")
        structure.selection = [0]
        tab.requestAddField()
        structure.fieldSheet?.name = "customer_id"
        structure.fieldSheet?.type = "INTEGER"
        tab.saveFieldSheet()
        await tab.currentLoad?.value
        _ = try? await client.run("UPDATE notes SET customer_id = 99")
        let keys = tab.foreignKeys
        tab.view = .foreignKeys
        await tab.currentLoad?.value
        check("S-070 Foreign Keys can be added to any SQLite table", keys.canAdd && keys.engineNote == nil)
        tab.requestAddForeignKey()
        await tab.currentLoad?.value
        guard let draft = keys.sheet else { return check("S-070 Add Foreign Key opens", false, keys.editError?.message ?? "") }
        await until { !draft.isLoadingReference }
        check("S-070 it points at the referenced table's key",
              draft.field == "customer_id" && draft.referencedTable == "customers" && draft.referencedField == "id",
              "\(draft.field) \(draft.referencedTable) \(draft.referencedField) \(draft.tables)")
        check("The Add Foreign Key sheet on a SQLite file shows the rebuild it runs, not MySQL's ALTER TABLE",
              draft.sql.hasPrefix("Rebuilds the table:") && draft.sql.contains("REFERENCES") && !draft.sql.contains("ADD CONSTRAINT"),
              draft.sql)
        tab.saveForeignKeySheet()
        await tab.currentLoad?.value
        check("S-070 a key whose rows have no parent is refused, and nothing changes",
              draft.error?.message == "Rows in “notes” would point at rows “customers” doesn’t have." && keys.keys.isEmpty,
              draft.error?.message ?? "no error")
        _ = try? await client.run("UPDATE notes SET customer_id = 1")
        tab.saveForeignKeySheet()
        await tab.currentLoad?.value
        let notes = await create(client, "notes")
        check("S-070 Add Foreign Key rebuilds the table with it",
              keys.keys.count == 1 && keys.sheet == nil && notes.contains("REFERENCES \"customers\" (\"id\")"),
              keys.editError?.message ?? draft.error?.message ?? notes)
        keys.selection = [0]
        tab.requestDeleteForeignKeys()
        tab.confirmDeleteForeignKeys()
        await tab.currentLoad?.value
        check("S-070 Delete Foreign Key rebuilds the table without it", keys.keys.isEmpty && keys.editError == nil,
              keys.editError?.message ?? "")
    }

    // MARK: Triggers

    private static func sqliteTriggers(_ tab: Session, _ client: DatabaseClient) async {
        let triggers = tab.triggers
        tab.view = .triggers
        tab.selectedObjectID = "table:products"
        await tab.currentLoad?.value
        await until { !triggers.triggers.isEmpty }
        check("S-070 Triggers reads UPDATE OF and WHEN", triggers.triggers.first?.columns == "stock"
                  && triggers.triggers.first?.statement.hasPrefix("WHEN NEW.stock < 0") == true,
              triggers.triggers.first.map { "\($0.columns) \($0.statement)" } ?? "none")
        tab.requestEditTrigger(row: 0)
        await tab.currentLoad?.value
        guard let edit = triggers.sheet else { return check("S-070 Edit Trigger opens", false) }
        edit.name = "products_stock_guard"
        tab.saveTriggerSheet()
        await tab.currentLoad?.value
        let saved = await create(client, "products_stock_guard")
        let count = await value(client, "SELECT count(*) FROM sqlite_schema WHERE type = 'trigger'")
        check("S-070 editing a trigger drops and creates it, keeping UPDATE OF and WHEN",
              saved.hasPrefix("CREATE TRIGGER \"products_stock_guard\" BEFORE UPDATE OF stock ON \"products\"")
                  && saved.contains("WHEN NEW.stock < 0") && count == "1",
              edit.error?.message ?? saved)

        tab.requestAddTrigger()
        await tab.currentLoad?.value
        guard let add = triggers.sheet else { return check("S-070 Add Trigger opens", false) }
        add.timing = .after
        add.event = .insert
        add.statement = "UPDATE products SET stock = 0 WHERE id = NEW.id AND NEW.stock IS NULL"
        tab.saveTriggerSheet()
        await tab.currentLoad?.value
        let added = await create(client, add.definition.name)
        check("S-070 a new trigger's statement is wrapped in BEGIN … END",
              added.contains("BEGIN\n  UPDATE products") && triggers.sheet == nil, add.error?.message ?? added)
        triggers.selection = IndexSet(triggers.triggers.indices.filter { triggers.triggers[$0].name == add.definition.name })
        tab.requestDeleteTriggers()
        tab.confirmDeleteTriggers()
        await tab.currentLoad?.value
        check("S-070 Delete Trigger drops it", triggers.triggers.count == 1, triggers.editError?.message ?? "")

        // The rebuild puts a table's triggers back.
        await showStructure(tab, "products")
        tab.editField(row: 4, column: 4, to: .text("5"))
        await tab.currentLoad?.value
        let guardName = await value(client, "SELECT name FROM sqlite_schema WHERE type = 'trigger' AND tbl_name = 'products'")
        check("S-070 a rebuild keeps the table's triggers", guardName == "products_stock_guard", tab.structure.editError?.message ?? "")
    }

    // MARK: Tables, views and Info

    private static func sqliteTablesAndViews(_ tab: Session, _ client: DatabaseClient) async {
        tab.view = .info
        tab.selectedObjectID = "table:settings"
        await tab.currentLoad?.value
        await until { tab.info.load.loadedFor?.hasSuffix("settings") == true }
        check("S-070 Info shows a table's options and rows, with no engine or character set",
              tab.info.sqliteOptions == ["WITHOUT ROWID"] && tab.info.sizeDetails.first?.label == "Rows" && !tab.info.canEdit
                  && tab.info.createStatement.hasPrefix("CREATE TABLE settings"),
              "\(tab.info.sqliteOptions ?? []) \(tab.info.sizeDetails.map(\.label))")

        tab.requestNewTable()
        guard let creator = tab.newTable else { return check("S-070 New Table opens", false) }
        creator.name = "tags"
        check("S-070 New Table needs no engine or character set", creator.isSQLite && creator.canCreate)
        await tab.createTable()?.value
        let tags = await create(client, "tags")
        check("S-070 New Table makes id INTEGER PRIMARY KEY", tags == "CREATE TABLE \"tags\" (\"id\" INTEGER PRIMARY KEY)",
              creator.createError?.message ?? tags)

        tab.requestRenameTable(["table:tags"])
        tab.renameText = "labels"
        await tab.commitRename()?.value
        check("S-070 Rename runs ALTER TABLE … RENAME TO", tab.objects.contains { $0.name == "labels" } && tab.alert == nil,
              tab.alert?.message ?? "")

        tab.requestDuplicateTable(["table:orders"])
        tab.tableDuplicator?.withRows = true
        await tab.runDuplicateTable()?.value
        let copy = [await value(client, "SELECT count(*) FROM orders_copy"),
                    await value(client, "SELECT count(*) FROM sqlite_schema WHERE type = 'index' AND tbl_name = 'orders_copy'")]
        check("S-070 Duplicate copies the table, its rows and its indexes", copy == ["5", "2"],
              tab.tableDuplicator?.error?.message ?? copy.map { $0 ?? "nil" }.joined(separator: ", "))

        tab.requestEmptyTables(["table:orders_copy"])
        await tab.confirmTableEdit()?.value
        let emptied = await value(client, "SELECT count(*) FROM orders_copy")
        check("S-070 Empty runs DELETE FROM", emptied == "0" && tab.alert == nil, tab.alert?.message ?? "")
        tab.requestDeleteTables(["table:orders_copy", "table:labels"])
        await tab.confirmTableEdit()?.value
        check("S-070 Delete drops each table", !tab.objects.contains { $0.name == "orders_copy" || $0.name == "labels" }
                  && tab.alert == nil, tab.alert?.message ?? "")

        // Views: New View, Edit View, Rename.
        tab.requestNewDefinition(.view)
        guard let view = tab.definitionDraft else { return check("S-070 New View opens", false) }
        view.name = "uk_customers"
        view.text = "SELECT name FROM customers WHERE nation = 'UK'"
        check("S-070 New View is CREATE VIEW, with no algorithm or security",
              view.isSQLite && view.statement == "CREATE VIEW \"uk_customers\" AS\nSELECT name FROM customers WHERE nation = 'UK'",
              view.statement)
        await tab.saveDefinition()?.value
        let ukCount = await value(client, "SELECT count(*) FROM uk_customers")
        check("S-070 New View makes it", ukCount == "2", view.error?.message ?? "")
        tab.requestEditDefinition(["view:uk_customers"])
        await tab.currentLoad?.value
        guard let editing = tab.definitionDraft else { return check("S-070 Edit View opens", false) }
        check("S-070 Edit View reads the SELECT", editing.text == "SELECT name FROM customers WHERE nation = 'UK'", editing.text)
        editing.text = "SELECT name, email FROM customers WHERE nation = 'UK'"
        await tab.saveDefinition()?.value
        let edited = await create(client, "uk_customers")
        check("S-070 Edit View drops and creates it", edited.contains("name, email"), editing.error?.message ?? edited)
        tab.requestRenameTable(["view:uk_customers"])
        tab.renameText = "british_customers"
        await tab.commitRename()?.value
        let british = await value(client, "SELECT count(*) FROM british_customers")
        check("S-070 Rename works on a view", british == "2", tab.alert?.message ?? "")
    }
}
