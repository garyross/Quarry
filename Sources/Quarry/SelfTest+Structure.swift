import AppKit
import QuarryKit
import QuarryControllers
import SwiftData

/// Self-test: Fields, indexes, foreign keys, triggers, views and routines (S-023 to S-026, S-030).
extension SelfTest {
    // MARK: S-023

    static func fieldChanges(session: Session) async {
        let name = "quarry_selftest_fields"
        guard let client = session.client else { return check("S-023 connected", false) }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        let table = "`quarry_demo`." + SQLQuote.identifier(name)
        _ = try? await client.run("DROP TABLE IF EXISTS " + table)
        _ = try? await client.run("CREATE TABLE \(table) (id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, "
            + "name VARCHAR(50) NOT NULL, price DECIMAL(10,2) NULL, created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "
            + "total INT AS (id * 2) VIRTUAL) DEFAULT CHARSET utf8mb4")
        _ = try? await client.run("INSERT INTO \(table) (name, price) VALUES ('Ada', 9.5)")
        try? await session.loadObjects(client, "quarry_demo")
        session.view = .structure
        session.selectedObjectID = "table:\(name)"
        await session.currentLoad?.value
        let structure = session.structure
        func columns() async -> [(name: String, type: String, defaultValue: String?, collation: String?)] {
            guard let result = try? await client.run(
                "SELECT COLUMN_NAME AS n, COLUMN_TYPE AS t, COLUMN_DEFAULT AS d, COLLATION_NAME AS c FROM information_schema.COLUMNS "
                    + "WHERE TABLE_SCHEMA = 'quarry_demo' AND TABLE_NAME = \(SQLQuote.mysqlLiteral(name)) ORDER BY ORDINAL_POSITION")
            else { return [] }
            return result.rows.indices.map { (result.string($0, "n") ?? "", result.string($0, "t") ?? "",
                                              result.string($0, "d"), result.string($0, "c")) }
        }
        check("S-023 Structure loads the fields for editing", structure.definitions.count == 5 && structure.canEdit,
              "\(structure.definitions.count) \(structure.load.error?.message ?? "")")
        check("S-023 a generated field isn't edited", !structure.canEdit(row: 4, column: 0) && !structure.canDrag(row: 4))
        check("S-023 Name, Type, Length, Default and Comment edit inline; the rest open the sheet",
              structure.canEdit(row: 1, column: 0) && structure.canEdit(row: 1, column: 1) && structure.canEdit(row: 1, column: 6)
                  && !structure.canEdit(row: 1, column: 3) && structure.opensSheet(row: 1, column: 3))

        // Content was shown before: a change makes it load again.
        session.editField(row: 1, column: 0, to: .text("full_name"))
        await session.currentLoad?.value
        var now = await columns()
        check("S-023 renaming inline runs one ALTER TABLE … CHANGE", now.map(\.name) == ["id", "full_name", "price", "created_at", "total"]
                  && now[1].type == "varchar(50)" && structure.editError == nil,
              "\(now.map(\.name)) \(structure.editError?.message ?? "")")
        check("S-023 after a change Content loads again", session.content.load.loadedFor == nil)

        session.editField(row: 1, column: 2, to: .text("abc"))
        await session.currentLoad?.value
        now = await columns()
        check("S-023 an error shows and the row goes back",
              structure.editError != nil && now[1].type == "varchar(50)" && structure.fields.rows[1][2].plainText == "50",
              "\(structure.editError?.message ?? "no error") \(structure.fields.rows[1][2].plainText ?? "")")

        session.editField(row: 2, column: 1, to: .text("int"))
        await session.currentLoad?.value
        now = await columns()
        check("S-023 a type change drops the length it can't use", now[2].type.hasPrefix("int") && structure.editError == nil,
              "\(now[2].type) \(structure.editError?.message ?? "")")
        session.editField(row: 2, column: 6, to: .text("5"))
        await session.currentLoad?.value
        now = await columns()
        check("S-023 a default typed inline is saved quoted", now[2].defaultValue == "5", now[2].defaultValue ?? "none")
        session.editField(row: 2, column: 6, to: .null)
        await session.currentLoad?.value
        check("S-023 Set to NULL sets DEFAULT NULL", await columns()[2].defaultValue == "NULL")

        structure.selection = [1]
        session.requestAddField()
        guard let add = structure.fieldSheet else { return check("S-023 Add Field opens its sheet", false) }
        check("S-023 Add Field goes after the selected field", add.isAdding && add.position == .after("full_name"))
        add.name = "price"
        check("S-023 a name the table has is refused", add.nameProblem != nil && !add.canSave)
        add.name = "note"
        add.type = "varchar"
        check("S-023 VARCHAR starts at 255", add.length == "255")
        add.defaultKind = .value
        add.defaultText = "none yet"
        add.comment = "Free text"
        check("S-023 the sheet shows its one statement", add.sql.hasPrefix("ALTER TABLE")
                  && add.sql.hasSuffix("AFTER `full_name`"), add.sql)
        session.saveFieldSheet()
        await session.currentLoad?.value
        now = await columns()
        check("S-023 Add makes the field where it was asked", structure.fieldSheet == nil && now.count == 6 && now[2].name == "note"
                  && now[2].type == "varchar(255)" && now[2].defaultValue == "'none yet'" && structure.selection == [2],
              "\(now.map(\.name)) \(now.count > 2 ? now[2].defaultValue ?? "" : "") \(add.error?.message ?? "")")

        session.requestEditField(row: 2)
        guard let edit = structure.fieldSheet else { return check("S-023 Edit Field opens its sheet", false) }
        await until { edit.catalog != nil }
        check("S-023 Edit Field starts from the field, its character set found from the collation",
              !edit.isAdding && edit.type == "varchar" && edit.charset == "utf8mb4" && edit.position == .after("full_name"),
              "\(edit.type) \(edit.charset ?? "nil") \(edit.position)")
        edit.type = "int"
        check("S-023 a type change in the sheet clears the collation and the text default",
              edit.collation == nil && edit.charset == nil && edit.defaultKind != .value && edit.length.isEmpty)
        edit.type = "text"
        edit.collation = "utf8mb4_bin"
        edit.position = .first
        session.saveFieldSheet()
        await session.currentLoad?.value
        now = await columns()
        check("S-023 Save changes the type, collation and position in one statement",
              now.first?.name == "note" && now.first?.type == "text" && now.first?.collation == "utf8mb4_bin",
              "\(now.map { "\($0.name):\($0.type):\($0.collation ?? "")" }) \(edit.error?.message ?? "")")

        session.requestEditField(row: 0)
        structure.fieldSheet?.name = "id"
        structure.fieldSheet?.name = "note"
        structure.fieldSheet?.type = "int"
        structure.fieldSheet?.extra = .autoIncrement
        session.saveFieldSheet()
        await session.currentLoad?.value
        check("S-023 a server error stays in the sheet", structure.fieldSheet?.error != nil)
        structure.fieldSheet = nil

        let fullName = structure.definitions.firstIndex { $0.name == "full_name" } ?? 0
        structure.selection = [fullName]
        session.duplicateField()
        await session.currentLoad?.value
        now = await columns()
        check("S-023 Duplicate Field adds a copy right after it", now.count == 7 && now[fullName + 1].name == "full_name_copy"
                  && now[fullName + 1].type == "varchar(50)", "\(now.map(\.name))")

        let last = structure.definitions.firstIndex { $0.name == "created_at" } ?? 0
        session.moveField(from: last, to: 0)
        await session.currentLoad?.value
        now = await columns()
        check("S-023 dragging a field moves it", now.first?.name == "created_at" && structure.selection == [0], "\(now.map(\.name))")
        structure.selection = [0]
        session.moveField(by: 1)
        await session.currentLoad?.value
        now = await columns()
        check("S-023 Move Field Down swaps it with the next", now.prefix(2).map(\.name) == ["note", "created_at"], "\(now.map(\.name))")

        let copy = structure.definitions.firstIndex { $0.name == "full_name_copy" } ?? 0
        let note = structure.definitions.firstIndex { $0.name == "note" } ?? 0
        structure.selection = [copy, note]
        structure.gridHasFocus = true
        check("S-023 the Table menu reads Delete 2 Fields…", session.menuSnapshot.selectedRowCount == 2 && session.menuSnapshot.canDeleteRows)
        session.requestDeleteFields()
        check("S-023 Delete asks first", structure.pendingDelete == ["note", "full_name_copy"], "\(structure.pendingDelete ?? [])")
        session.confirmDeleteFields()
        await session.currentLoad?.value
        now = await columns()
        check("S-023 Delete drops the fields in one ALTER TABLE", now.map(\.name) == ["created_at", "id", "full_name", "price", "total"],
              "\(now.map(\.name))")
        let rows = try? await client.run("SELECT full_name FROM \(table)")
        check("S-023 the rows keep their values", rows?.string(0, "full_name") == "Ada")

        _ = try? await client.run("DROP TABLE IF EXISTS " + table)
        session.view = .content
        session.selectedObjectID = nil
        try? await session.loadObjects(client, "quarry_demo")
    }

    // MARK: S-024

    static func indexChanges(session: Session) async {
        let name = "quarry_selftest_indexes"
        guard let client = session.client else { return check("S-024 connected", false) }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        let table = "`quarry_demo`." + SQLQuote.identifier(name)
        _ = try? await client.run("DROP TABLE IF EXISTS " + table)
        _ = try? await client.run("CREATE TABLE \(table) (id INT NOT NULL, name VARCHAR(50) NOT NULL, bio TEXT NULL, "
            + "age INT NULL) DEFAULT CHARSET utf8mb4")
        try? await session.loadObjects(client, "quarry_demo")
        session.view = .structure
        session.selectedObjectID = "table:\(name)"
        await session.currentLoad?.value
        let structure = session.structure
        func indexes() async -> [String: [String]] {
            guard let result = try? await client.run("SHOW INDEX FROM " + table) else { return [:] }
            var found: [String: [String]] = [:]
            for row in result.rows.indices {
                let field = (result.string(row, "Column_name") ?? "") + (result.string(row, "Sub_part").map { "(\($0))" } ?? "")
                found[result.string(row, "Key_name") ?? "", default: []].append(field)
            }
            return found
        }

        structure.selection = []
        session.requestAddIndex()
        guard let primary = structure.indexSheet else { return check("S-024 Add Index opens its sheet", false) }
        check("S-024 a table without a primary key starts on Primary Key", primary.kind == .primary
                  && primary.parts.map(\.field) == ["id"], "\(primary.kind) \(primary.parts.map(\.field))")
        session.saveIndexSheet()
        await session.currentLoad?.value
        check("S-024 Add makes the primary key", await indexes()["PRIMARY"] == ["id"] && structure.indexSheet == nil,
              "\(await indexes()) \(primary.error?.message ?? "")")

        structure.selection = [1, 2]
        session.requestAddIndex()
        guard let add = structure.indexSheet else { return check("S-024 Add Index opens again", false) }
        check("S-024 with a primary key it starts on Index, holding the selected fields",
              add.kind == .index && add.parts.map(\.field) == ["name", "bio"] && add.hasPrimaryKey)
        check("S-024 a Text field needs a prefix", add.rule(for: add.parts[1]) == .required && !add.canSave)
        add.parts[1].prefix = "20"
        add.name = "primary"
        check("S-024 PRIMARY is refused as a name", add.nameProblem != nil && !add.canSave)
        add.name = "idx_name_bio"
        add.storage = .btree
        check("S-024 the sheet shows its one statement", add.canSave
                  && add.sql.hasSuffix("ADD INDEX `idx_name_bio` USING BTREE (`name`, `bio`(20))"),
              add.sql)
        session.saveIndexSheet()
        await session.currentLoad?.value
        let afterAdd = await indexes()
        check("S-024 Add makes an index on two fields with a prefix", afterAdd["idx_name_bio"] == ["name", "bio(20)"],
              "\(afterAdd) \(add.error?.message ?? "")")
        check("S-024 the new index shows and is selected", structure.selectedIndexNames == ["idx_name_bio"]
                  && structure.indexRowNames.filter { $0 == "idx_name_bio" }.count == 2, "\(structure.selectedIndexNames)")

        session.requestAddIndex()
        structure.indexSheet?.kind = .unique
        structure.indexSheet?.name = "IDX_NAME_BIO"
        check("S-024 a name the table has is refused", structure.indexSheet?.nameProblem != nil)
        structure.indexSheet?.name = "u_age"
        structure.indexSheet?.parts = [IndexDraft.Part(field: "age")]
        structure.indexSheet?.storage = .hash
        structure.indexSheet?.keyBlockSize = "8"
        session.saveIndexSheet()
        await session.currentLoad?.value
        check("S-024 a Unique index with HASH storage and a key block size", await indexes()["u_age"] == ["age"]
                  || structure.indexSheet?.error != nil, "\(await indexes())")
        structure.indexSheet = nil

        let rows = structure.indexRowNames.indices.filter { structure.indexRowNames[$0] != "u_age" }
        structure.indexSelection = IndexSet(rows)
        structure.indexGridHasFocus = true
        check("S-024 the Table menu reads Delete 2 Indexes…", session.menuSnapshot.canDeleteIndexes
                  && session.menuSnapshot.deleteIndexTitle == "Delete 2 Indexes…", session.menuSnapshot.deleteIndexTitle)
        session.requestDeleteIndexes()
        check("S-024 Delete asks first, once per index", structure.pendingIndexDelete == ["PRIMARY", "idx_name_bio"],
              "\(structure.pendingIndexDelete ?? [])")
        session.confirmDeleteIndexes()
        await session.currentLoad?.value
        let left = await indexes()
        check("S-024 Delete drops them in one ALTER TABLE", left["PRIMARY"] == nil && left["idx_name_bio"] == nil
                  && structure.editError == nil, "\(left) \(structure.editError?.message ?? "")")

        _ = try? await client.run("DROP TABLE IF EXISTS " + table)
        session.view = .content
        session.selectedObjectID = nil
        try? await session.loadObjects(client, "quarry_demo")
    }

    // MARK: S-025

    static func foreignKeyChanges(session: Session) async {
        guard let client = session.client else { return check("S-025 connected", false) }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        let parent = "quarry_selftest_fk_parent", child = "quarry_selftest_fk_child", legacy = "quarry_selftest_fk_myisam"
        func qualified(_ name: String) -> String { "`quarry_demo`." + SQLQuote.identifier(name) }
        for name in [child, parent, legacy] { _ = try? await client.run("DROP TABLE IF EXISTS " + qualified(name)) }
        _ = try? await client.run("CREATE TABLE \(qualified(parent)) (id INT UNSIGNED NOT NULL PRIMARY KEY, "
            + "code VARCHAR(10) NOT NULL, label VARCHAR(10) NULL, big BIGINT UNSIGNED NULL, UNIQUE KEY code (code)) "
            + "ENGINE=InnoDB DEFAULT CHARSET utf8mb4")
        _ = try? await client.run("CREATE TABLE \(qualified(child)) (id INT NOT NULL PRIMARY KEY, parent_id INT UNSIGNED NULL, "
            + "signed_id INT NULL, code VARCHAR(20) NOT NULL) ENGINE=InnoDB DEFAULT CHARSET utf8mb4")
        _ = try? await client.run("CREATE TABLE \(qualified(legacy)) (id INT PRIMARY KEY) ENGINE=MyISAM")
        try? await session.loadObjects(client, "quarry_demo")
        session.view = .foreignKeys
        session.selectedObjectID = "table:\(child)"
        await session.currentLoad?.value
        let keys = session.foreignKeys
        func rules() async -> [String: String] {
            guard let result = try? await client.run("""
                SELECT CONSTRAINT_NAME AS n, CONCAT(UPDATE_RULE, '/', DELETE_RULE) AS r
                FROM information_schema.REFERENTIAL_CONSTRAINTS
                WHERE CONSTRAINT_SCHEMA = 'quarry_demo' AND TABLE_NAME = \(SQLQuote.mysqlLiteral(child))
                """) else { return [:] }
            var found: [String: String] = [:]
            for row in result.rows.indices { found[result.string(row, "n") ?? ""] = result.string(row, "r") ?? "" }
            return found
        }

        check("S-025 an InnoDB table can have foreign keys", keys.canAdd && keys.engineNote == nil
                  && session.menuSnapshot.canAddForeignKey)
        session.requestAddForeignKey()
        await session.currentLoad?.value
        guard let draft = keys.sheet else { return check("S-025 Add Foreign Key opens its sheet", false) }
        check("S-025 the sheet starts on the first _id field and lists InnoDB tables only",
              draft.field == "parent_id" && draft.tables.contains(parent) && !draft.tables.contains(legacy),
                  "\(draft.field) \(draft.tables)")
        draft.referencedTable = parent
        session.foreignKeyTableChanged()
        await session.currentLoad?.value
        check("S-025 only fields of the same type that lead an index are offered",
              draft.candidates == ["id"] && draft.referencedField == "id", "\(draft.candidates)")
        draft.field = "signed_id"
        check("S-025 a signed field finds no unsigned reference", draft.candidates.isEmpty
                  && draft.referenceProblem != nil && !draft.canSave, draft.referenceProblem ?? "")
        draft.field = "code"
        check("S-025 a string field is offered the indexed string field", draft.candidates == ["code"], "\(draft.candidates)")
        draft.onDelete = .setNull
        check("S-025 Set NULL is refused on a NOT NULL field", !draft.nullAllowed && !draft.canSave)
        draft.field = "parent_id"
        draft.onDelete = .setNull
        draft.onUpdate = .cascade
        draft.name = "fk_selftest_parent"
        check("S-025 the sheet shows its one statement", draft.canSave && draft.sql
                  .hasSuffix("REFERENCES `quarry_demo`.`\(parent)` (`id`) ON DELETE SET NULL ON UPDATE CASCADE"),
              draft.sql)
        session.saveForeignKeySheet()
        await session.currentLoad?.value
        check("S-025 Add makes the foreign key with its actions", await rules()["fk_selftest_parent"] == "CASCADE/SET NULL"
                  && keys.sheet == nil, "\(await rules()) \(draft.error?.message ?? "")")
        check("S-025 the new key shows and is selected", keys.selectedNames == ["fk_selftest_parent"], "\(keys.selectedNames)")

        session.requestAddForeignKey()
        await session.currentLoad?.value
        guard let second = keys.sheet else { return check("S-025 Add Foreign Key opens again", false) }
        second.name = "FK_SELFTEST_PARENT"
        check("S-025 a name the table has is refused", second.nameProblem != nil && !second.canSave)
        second.name = ""
        second.field = "code"
        second.referencedTable = parent
        session.foreignKeyTableChanged()
        await session.currentLoad?.value
        session.saveForeignKeySheet()
        await session.currentLoad?.value
        check("S-025 an unnamed key gets the server's name", keys.keys.count == 2, "\(keys.keys.map(\.name)) \(second.error?.message ?? "")")

        keys.selection = IndexSet(keys.keys.indices)
        keys.gridHasFocus = true
        check("S-025 the Table menu reads Delete 2 Foreign Keys…", session.menuSnapshot.canDeleteForeignKeys
                  && session.menuSnapshot.deleteForeignKeyTitle == "Delete 2 Foreign Keys…", session.menuSnapshot.deleteForeignKeyTitle)
        session.requestDeleteForeignKeys()
        check("S-025 Delete asks first", keys.pendingDelete?.count == 2)
        session.confirmDeleteForeignKeys()
        await session.currentLoad?.value
        check("S-025 Delete drops them in one ALTER TABLE", await rules().isEmpty && keys.keys.isEmpty && keys.editError == nil,
              "\(await rules()) \(keys.editError?.message ?? "")")

        session.selectedObjectID = "table:\(legacy)"
        await session.currentLoad?.value
        check("S-025 a MyISAM table says foreign keys need InnoDB", keys.engineNote?.contains("MyISAM") == true
                  && !keys.canAdd, keys.engineNote ?? "")

        for name in [child, parent, legacy] { _ = try? await client.run("DROP TABLE IF EXISTS " + qualified(name)) }
        session.view = .content
        session.selectedObjectID = nil
        try? await session.loadObjects(client, "quarry_demo")
    }

    // MARK: S-026

    static func triggerChanges(session: Session) async {
        guard let client = session.client else { return check("S-026 connected", false) }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        let table = "quarry_selftest_triggers"
        let qualified = "`quarry_demo`." + SQLQuote.identifier(table)
        _ = try? await client.run("DROP TABLE IF EXISTS " + qualified)
        _ = try? await client.run("CREATE TABLE \(qualified) (id INT PRIMARY KEY, amount INT NOT NULL DEFAULT 0)")
        try? await session.loadObjects(client, "quarry_demo")
        session.view = .triggers
        session.selectedObjectID = "table:\(table)"
        await session.currentLoad?.value
        let triggers = session.triggers
        func statement(_ name: String) async -> String? {
            let result = try? await client.run("SELECT ACTION_TIMING AS t, ACTION_STATEMENT AS s FROM information_schema.TRIGGERS "
                + "WHERE TRIGGER_SCHEMA = 'quarry_demo' AND TRIGGER_NAME = " + SQLQuote.mysqlLiteral(name))
            guard let result, !result.rows.isEmpty else { return nil }
            return (result.string(0, "t") ?? "") + " " + (result.string(0, "s") ?? "")
        }

        check("S-026 a table with no triggers can add one", triggers.canAdd && triggers.triggers.isEmpty
                  && session.menuSnapshot.canAddTrigger)
        session.requestAddTrigger()
        await session.currentLoad?.value
        guard let draft = triggers.sheet else { return check("S-026 Add Trigger opens its sheet", false) }
        check("S-026 the sheet suggests a name from Action Time and Event",
              draft.name == "\(table)_before_insert" && draft.saveTitle == "Add", draft.name)
        draft.event = .update
        check("S-026 the suggested name follows the Event", draft.name == "\(table)_before_update", draft.name)
        draft.name = "ORDERS_BEFORE_UPDATE"
        check("S-026 a name another table's trigger has is refused", draft.nameProblem != nil && !draft.canSave)
        draft.name = "selftest_clamp"
        draft.statement = "IF NEW.amount < 0 THEN SET NEW.amount = 0; END IF;"
        check("S-026 the sheet shows the statement's start",
              draft.header == "CREATE TRIGGER `selftest_clamp` BEFORE UPDATE ON `\(table)` FOR EACH ROW", draft.header)
        session.saveTriggerSheet()
        await session.currentLoad?.value
        let added = await statement("selftest_clamp")
        check("S-026 Add creates the trigger and selects it", triggers.sheet == nil
                  && triggers.selectedNames == ["selftest_clamp"] && added?.hasPrefix("BEFORE IF") == true,
              "\(triggers.selectedNames) \(draft.error?.message ?? "")")

        triggers.gridHasFocus = true
        check("S-026 the Table menu offers Edit Trigger… and Delete Trigger…", session.menuSnapshot.canEditTrigger
                  && session.menuSnapshot.canDeleteTriggers && session.menuSnapshot.deleteTriggerTitle == "Delete Trigger…")
        session.requestEditTrigger()
        await session.currentLoad?.value
        guard let edit = triggers.sheet else { return check("S-026 Edit Trigger opens its sheet", false) }
        check("S-026 Edit fills the sheet in", edit.isEdit && edit.name == "selftest_clamp" && edit.timing == .before
                  && edit.event == .update && edit.statement.hasPrefix("IF NEW.amount") && !edit.canSave && edit.saveTitle == "Save")
        edit.timing = .after
        edit.statement = "SET @selftest_trigger = = NEW.amount"
        session.saveTriggerSheet()
        await session.currentLoad?.value
        check("S-026 a failed edit keeps the sheet open with the error", triggers.sheet === edit
                  && edit.error?.code == 1064 && edit.error?.suggestion == "The trigger wasn\u{2019}t changed.",
              "\(edit.error?.message ?? "none") \(edit.error?.suggestion ?? "")")
        check("S-026 a failed edit restores the original", await statement("selftest_clamp")?.hasPrefix("BEFORE IF NEW.amount") == true,
              await statement("selftest_clamp") ?? "gone")
        edit.statement = "SET @selftest_trigger = NEW.amount"
        session.saveTriggerSheet()
        await session.currentLoad?.value
        let saved = await statement("selftest_clamp")
        check("S-026 Save replaces the trigger in one step", triggers.sheet == nil
                  && saved == "AFTER SET @selftest_trigger = NEW.amount"
                  && triggers.triggers.map(\.name) == ["selftest_clamp"], saved ?? "gone")
        _ = try? await client.run("INSERT INTO \(qualified) VALUES (1, 5)")
        _ = try? await client.run("UPDATE \(qualified) SET amount = 7 WHERE id = 1")
        let fired = try? await client.run("SELECT @selftest_trigger AS v")
        check("S-026 the edited trigger runs", fired?.string(0, "v") == "7", fired?.string(0, "v") ?? "")

        triggers.selection = [0]
        triggers.gridHasFocus = true
        session.requestDeleteTriggers()
        check("S-026 Delete asks first", triggers.pendingDelete == ["selftest_clamp"])
        session.confirmDeleteTriggers()
        await session.currentLoad?.value
        let deleted = await statement("selftest_clamp") == nil
        check("S-026 Delete drops the trigger", deleted && triggers.triggers.isEmpty
                  && triggers.editError == nil, triggers.editError?.message ?? "")

        _ = try? await client.run("DROP TABLE IF EXISTS " + qualified)
        session.view = .content
        session.selectedObjectID = nil
        try? await session.loadObjects(client, "quarry_demo")
    }

    // MARK: S-030

    static func definitions(session: Session) async {
        guard let client = session.client else { return check("S-030 connected", false) }
        session.database = "quarry_demo"
        await session.currentLoad?.value
        let viewName = "quarry_selftest_view", procName = "quarry_selftest_proc", funcName = "quarry_selftest_func"
        _ = try? await client.run("DROP VIEW IF EXISTS `quarry_demo`.`\(viewName)`")
        _ = try? await client.run("DROP PROCEDURE IF EXISTS `quarry_demo`.`\(procName)`")
        _ = try? await client.run("DROP FUNCTION IF EXISTS `quarry_demo`.`\(funcName)`")
        try? await session.loadObjects(client, "quarry_demo")
        func routineBody(_ name: String) async -> String? {
            let result = try? await client.run("SELECT ROUTINE_DEFINITION FROM information_schema.ROUTINES "
                + "WHERE ROUTINE_SCHEMA = 'quarry_demo' AND ROUTINE_NAME = " + SQLQuote.mysqlLiteral(name))
            guard let result, !result.rows.isEmpty else { return nil }
            return result.string(0, "ROUTINE_DEFINITION")
        }

        // A new view.
        session.requestNewDefinition(.view)
        guard let view = session.definitionDraft else { return check("S-030 New View… opens its sheet", false) }
        check("S-030 New View starts empty", view.title == "New View in “quarry_demo”" && view.saveTitle == "Create" && !view.canSave,
              view.title)
        view.name = "Orders"
        check("S-030 a view can't take a table's name", view.nameProblem == "A table or view named “Orders” already exists.",
              view.nameProblem ?? "no problem")
        view.name = viewName
        view.text = "SELECT id, total FROM orders WHERE total > 100;"
        view.algorithm = .merge
        check("S-030 the sheet shows the statement it runs",
              view.statement == "CREATE ALGORITHM=MERGE VIEW `quarry_demo`.`\(viewName)` AS\nSELECT id, total FROM orders WHERE total > 100",
              view.statement)
        await session.saveDefinition()?.value
        check("S-030 a new view appears in the sidebar with the view symbol and opens on Content",
              session.definitionDraft == nil && session.selectedObject == DBObject(name: viewName, kind: .view)
              && ObjectSidebar.symbol(.view) == "eye" && session.view == .content,
              view.error?.message ?? "\(session.selectedObjectID ?? "nothing") \(session.view)")

        // Edit the view: its options come back, a change is CREATE OR REPLACE.
        await until { MenuState.shared.snapshot.editDefinitionTitle == "Edit View…" }
        check("S-030 Table > Edit View… follows the selection", session.menuSnapshot.canEditDefinition
                  && session.menuSnapshot.editDefinitionTitle == "Edit View…")
        session.requestEditDefinition()
        await session.currentLoad?.value
        guard let edit = session.definitionDraft else { return check("S-030 Edit View… opens its sheet", false) }
        check("S-030 Edit View reads the definition", edit.title == "Edit View “\(viewName)”" && edit.algorithm == .merge
                  && edit.text.contains("total") && !edit.canSave, edit.error?.message ?? edit.text)
        edit.checkOption = .cascaded
        check("S-030 a view edit replaces it in one statement", edit.plan.drop == nil && edit.statement.hasPrefix("CREATE OR REPLACE"))
        await session.saveDefinition()?.value
        let option = try? await client.run("SELECT CHECK_OPTION FROM information_schema.VIEWS WHERE TABLE_SCHEMA = 'quarry_demo' "
            + "AND TABLE_NAME = '\(viewName)'")
        check("S-030 Save changes the view", session.definitionDraft == nil && option?.string(0, "CHECK_OPTION") == "CASCADED",
              edit.error?.message ?? option?.string(0, "CHECK_OPTION") ?? "none")

        // A new procedure, then an edit that fails and one that works.
        session.requestNewDefinition(.procedure)
        guard let proc = session.definitionDraft else { return check("S-030 New Procedure… opens its sheet", false) }
        proc.name = procName
        proc.parameters = "IN n INT"
        proc.text = "BEGIN\n  SELECT n * 2 AS doubled;\nEND"
        await session.saveDefinition()?.value
        check("S-030 a new procedure is selected on Info", session.definitionDraft == nil
                  && session.selectedObject == DBObject(name: procName, kind: .procedure) && session.view == .info,
              proc.error?.message ?? "")
        session.requestEditDefinition(["procedure:\(procName)"])
        await session.currentLoad?.value
        guard let procEdit = session.definitionDraft else { return check("S-030 Edit Procedure… opens its sheet", false) }
        check("S-030 Edit Procedure reads its parameters and body", procEdit.parameters == "IN n INT"
                  && procEdit.text.contains("n * 2"), procEdit.error?.message ?? "\(procEdit.parameters) \(procEdit.text)")
        check("S-030 a procedure edit is a drop and a create", procEdit.plan.drop == "DROP PROCEDURE `quarry_demo`.`\(procName)`"
                  && procEdit.plan.restore.count == 2)
        procEdit.text = "BEGIN\n  SELEC n;\nEND"
        await session.saveDefinition()?.value
        let kept = await routineBody(procName)
        check("S-030 a failed edit keeps the old body and the sheet", session.definitionDraft === procEdit
                  && procEdit.error != nil && procEdit.error?.suggestion == "The procedure wasn’t changed."
                  && kept?.contains("n * 2") == true, "\(procEdit.error?.suggestion ?? "no error") \(kept ?? "gone")")
        procEdit.text = "BEGIN\n  SELECT n * 3 AS tripled;\nEND"
        await session.saveDefinition()?.value
        let changed = await routineBody(procName)
        check("S-030 a working edit replaces the body", session.definitionDraft == nil && changed?.contains("n * 3") == true,
              procEdit.error?.message ?? changed ?? "gone")

        // A new function that runs.
        session.requestNewDefinition(.function)
        guard let fn = session.definitionDraft else { return check("S-030 New Function… opens its sheet", false) }
        check("S-030 a function starts with a return type", fn.returns == "INT" && fn.text.contains("RETURN"))
        fn.name = funcName
        fn.parameters = "x INT"
        fn.deterministic = true
        fn.dataAccess = .noSQL
        fn.text = "RETURN x + 1"
        await session.saveDefinition()?.value
        let answer = try? await client.run("SELECT `quarry_demo`.`\(funcName)`(41) AS a")
        check("S-030 a new function runs", session.definitionDraft == nil && answer?.string(0, "a") == "42",
              fn.error?.message ?? answer?.string(0, "a") ?? "no answer")
        await until { MenuState.shared.snapshot.editDefinitionTitle == "Edit Function…" }
        check("S-030 the menu says Edit Function…", MenuState.shared.snapshot.editDefinitionTitle == "Edit Function…")
        session.requestEditDefinition()
        await session.currentLoad?.value
        let fnEdit = session.definitionDraft
        check("S-030 Edit Function reads its return type and characteristics",
              fnEdit?.returns.lowercased().hasPrefix("int") == true && fnEdit?.deterministic == true && fnEdit?.dataAccess == .noSQL,
              fnEdit?.error?.message ?? "\(fnEdit?.returns ?? "") \(fnEdit?.deterministic ?? false)")
        session.definitionDraft = nil

        // Delete routines and the view from the sidebar.
        let ids: Set<String> = ["procedure:\(procName)", "function:\(funcName)", "view:\(viewName)"]
        check("S-030 Delete names routines", session.objectActions(["procedure:\(procName)"]).deleteTitle
                  == "Delete Procedure…" && session.objectActions(ids).delete.count == 3)
        session.requestDeleteTables(ids)
        check("S-030 the delete alert counts every item", session.alert?.tableEdit?.title == "Delete 3 items?",
              session.alert?.tableEdit?.title ?? "no alert")
        await session.confirmTableEdit()?.value
        check("S-030 Delete drops views and routines", !session.objects.contains { ids.contains($0.id) }
                  && session.alert == nil, session.alert?.message ?? "")
        session.view = .content
        session.selectedObjectID = "table:customers"
        await session.currentLoad?.value
    }
}
