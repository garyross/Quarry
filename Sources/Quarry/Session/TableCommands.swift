import AppKit
import QuarryKit
import SwiftUI

/// The Table menu. Its last items follow the view: rows on Content, fields
/// and indexes on Structure, and so on (docs/DESIGN.md §4, `CommandMap`).
struct TableCommands: Commands {
    @ObservedObject var state: MenuState
    private var menu: MenuState.Snapshot { state.snapshot }
    private var responder: MenuState.Responder { state.responder }
    private var session: Session? { MenuState.shared.active }

    var body: some Commands {
        CommandMenu("Table") {
            Button("New Table…") { session?.requestNewTable() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!menu.creatableKinds.contains(.table))
            Button("New View…") { session?.requestNewDefinition(.view) }
                .keyboardShortcut("v", modifiers: [.command, .option, .control])
                .disabled(!menu.creatableKinds.contains(.view))
            Button("New Procedure…") { session?.requestNewDefinition(.procedure) }
                .keyboardShortcut("p", modifiers: [.command, .option, .control])
                .disabled(!menu.creatableKinds.contains(.procedure))
                .serverOnly("New Procedure…", on: menu.isSQLite)
            Button("New Function…") { session?.requestNewDefinition(.function) }
                .keyboardShortcut("u", modifiers: [.command, .option, .control])
                .disabled(!menu.creatableKinds.contains(.function))
                .serverOnly("New Function…", on: menu.isSQLite)
            Button(menu.editDefinitionTitle) { session?.requestEditDefinition() }
                .keyboardShortcut("e", modifiers: [.command, .option, .control])
                .disabled(!menu.canEditDefinition)
            Divider()
            Button(menu.renameTitle) { session?.requestRenameTable() }
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(!menu.canRenameTable)
            Button("Duplicate Table…") { session?.requestDuplicateTable() }
                .keyboardShortcut("d", modifiers: [.command, .control])
                .disabled(!menu.canDuplicateTable)
            Button(menu.emptyTitle) { session?.requestEmptyTables() }
                .keyboardShortcut(.delete, modifiers: [.command, .control])
                .disabled(!menu.canEmptyTables)
            Button(menu.deleteTitle) { session?.requestDeleteTables() }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(!menu.canDeleteTables)
            Divider()
            // Sequel Pro's ⌥⌘S is Save Filter here (S-062), so Show moves to ⌃⌘C.
            Button("Show Create Statement…") { session?.requestShowCreateStatement() }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(!menu.canShowCreateStatement)
            Button("Copy Create Statement") { session?.copyCreateStatement() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!menu.canShowCreateStatement)
            // S-029: no shortcuts, like the Database menu's tools: they run
            // rarely, and Repair and Optimize rebuild tables.
            Menu("Maintenance") {
                ForEach(TableOperation.allCases) { operation in
                    Button(menu.tableOperationTitles[operation] ?? "\(operation.verb) Table") {
                        session?.runTableOperation(operation)
                    }
                    .disabled(menu.tableOperationTitles[operation] == nil)
                    .serverOnly("\(operation.verb) Table", on: menu.isSQLite && !operation.works(on: .sqlite))
                }
            }
            .disabled(menu.tableOperationTitles.isEmpty)
            Divider()
            Button("Filter Content") { session?.focusContentFilter() }
                .keyboardShortcut("f")
                .disabled(!menu.canFilter)
            Button("Add Filter Rule") { session?.addFilterRule() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!menu.canFilter)
            Button("Add Filter Group") { session?.addFilterGroup() }
                .keyboardShortcut("f", modifiers: [.command, .shift, .option])
                .disabled(!menu.canFilter)
            Button("Add WHERE Clause") { session?.addTypedClause() }
                .keyboardShortcut("f", modifiers: [.command, .option, .control])
                .disabled(!menu.canFilter)
            Button("Save Filter…") { session?.requestSaveFilter() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!menu.canSaveFilter)
            Menu("Saved Filters") {
                ForEach(menu.savedFilters, id: \.id) { filter in
                    Button(filter.name) { session?.openSavedFilter(filter.id) }
                }
            }
            .disabled(menu.savedFilters.isEmpty)
            Button("Clear Filter") { session?.clearFilter() }
                .disabled(!menu.isFiltered)
            Divider()
            // S-012: sent to the focused grid, which knows the cell being edited.
            Button("Open in Field Editor") { NSApp.sendAction(#selector(GridCopying.openInFieldEditor(_:)), to: nil, from: nil) }
                // ⌃⌘E: ⇧⌘E is Sequel Pro's Export… (S-041).
                .keyboardShortcut("e", modifiers: [.command, .control])
                .disabled(!responder.canOpenFieldEditor)
            Button("Open Referenced Row") { session?.openReferencedRow() }
                .keyboardShortcut(.downArrow)
                .disabled(!menu.canOpenReferencedRow)
            Button("Open Referenced Row in New Tab") { session?.openReferencedRowInNewTab() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!menu.canOpenReferencedRow)
            Button(menu.openInNewTabTitle) { session?.openObjectInNewTab() }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(menu.phase != .connected || !menu.hasObject)
            if menu.view == .structure {
                // S-023: the same commands act on Structure's fields.
                Button("Edit Field…") { session?.requestEditField() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(!menu.canEditField)
                Button("Add Field…") { session?.requestAddField() }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                    .disabled(!menu.canAddRow)
                Button("Duplicate Field") { session?.duplicateField() }
                    .keyboardShortcut("d", modifiers: [.command, .shift, .option])
                    .disabled(!menu.canDuplicateRow)
                if menu.indexGridHasFocus {
                    Button(menu.deleteIndexTitle) { session?.requestDeleteIndexes() }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(!menu.canDeleteIndexes)
                } else {
                    Button(menu.selectedRowCount > 1 ? "Delete \(menu.selectedRowCount) Fields…" : "Delete Field…") {
                        session?.requestDeleteFields()
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!menu.canDeleteRows)
                }
                Button("Move Field Up") { session?.moveField(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                    .disabled(!menu.canMoveFieldUp)
                Button("Move Field Down") { session?.moveField(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                    .disabled(!menu.canMoveFieldDown)
                Divider()
                Button("Add Index…") { session?.requestAddIndex() }
                    .keyboardShortcut("a", modifiers: [.command, .option, .control])
                    .disabled(!menu.canAddIndex)
            } else if menu.view == .foreignKeys {
                Button("Add Foreign Key…") { session?.requestAddForeignKey() }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                    .disabled(!menu.canAddForeignKey)
                Button(menu.deleteForeignKeyTitle) { session?.requestDeleteForeignKeys() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!menu.canDeleteForeignKeys)
            } else if menu.view == .triggers {
                Button("Add Trigger…") { session?.requestAddTrigger() }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                    .disabled(!menu.canAddTrigger)
                Button("Edit Trigger…") { session?.requestEditTrigger() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(!menu.canEditTrigger)
                Button(menu.deleteTriggerTitle) { session?.requestDeleteTriggers() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!menu.canDeleteTriggers)
            } else if menu.view == .info {
                Button("Reset Auto Increment") { session?.resetAutoIncrement() }
                    .keyboardShortcut("r", modifiers: [.command, .option, .control])
                    .disabled(!menu.canResetAutoIncrement)
            } else {
                Button("Add Row") { session?.addRow() }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                    .disabled(!menu.canAddRow)
                // ⇧⌘D is Go to Database, as in Sequel Pro (S-020).
                Button("Duplicate Row") { session?.duplicateRow() }
                    .keyboardShortcut("d", modifiers: [.command, .shift, .option])
                    .disabled(!menu.canDuplicateRow)
                Button(menu.selectedRowCount > 1 ? "Delete \(menu.selectedRowCount) Rows…" : "Delete Row…") { session?.deleteRows() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!menu.canDeleteRows)
            }
        }
    }
}
