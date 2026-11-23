import AppKit
import QuarryKit

/// Row commands on a grid (S-010): the context menu, the three Copy commands,
/// and the Delete key. Copy works on every grid; adding and deleting rows only
/// where the owner passes `RowActions` (Content on a table).
extension DataGrid {
    struct RowActions {
        var canAdd: () -> Bool
        var canDuplicate: () -> Bool
        var canDelete: () -> Bool
        var add: () -> Void
        var duplicate: () -> Void
        var delete: () -> Void
        /// "Row" or "Field": the menu's titles (S-023).
        var noun = "Row"
        /// Add opens a sheet, so its title ends in "…".
        var addsWithSheet = false
        /// Edit Field…: double-clicking a cell that isn't edited inline, and the row menu. Nil leaves it out.
        var edit: ((_ row: Int) -> Void)?
        /// False leaves Duplicate out of the row menu (Structure's indexes, S-024).
        var duplicates = true
        /// The plural for the Delete title, when it isn't the noun plus "s".
        var plural: String?
        /// What Delete counts, when it isn't the selected rows (an index spans several rows).
        var deleteCount: (() -> Int)?
    }

    /// Dragging rows to reorder them (Structure's fields, S-023).
    struct RowReorder {
        var canDrag: (_ row: Int) -> Bool
        /// `destination` is the row the drop lands before (the row count for the end).
        var move: (_ source: Int, _ destination: Int) -> Void
    }

    /// Reports from the grid to its owner.
    struct Reports {
        var selection: (IndexSet) -> Void = { _ in }
        /// True while the table itself is first responder (not a cell's editor).
        var focus: (Bool) -> Void = { _ in }
    }
}

extension DataGrid.Coordinator: NSMenuDelegate {
    enum CopyStyle { case values, withNames, insert }

    func makeRowMenu() -> NSMenu {
        let menu = NSMenu(title: "Rows")
        menu.delegate = self
        return menu
    }

    /// Built when it opens, so it shows only what applies to the clicked rows.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table else { return }
        // Right-clicking outside the selection selects the clicked row, as in Finder.
        if table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
        // Now, so the owner's canDuplicate and canDelete see the clicked row.
        reports.selection(table.selectedRowIndexes)
        func item(_ title: String, _ action: Selector, _ symbol: String, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        let selected = !table.selectedRowIndexes.isEmpty
        item("Copy", #selector(copyValues), "doc.on.doc", enabled: selected)
        item("Copy with Column Names", #selector(copyWithNames), "tablecells", enabled: selected)
        if insertTable != nil {
            item("Copy as SQL INSERT", #selector(copyInsert), "chevron.left.forwardslash.chevron.right", enabled: selected)
        }
        // S-017: the clicked row's foreign keys, the clicked cell's first.
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        if let links, row >= 0 {
            var order = table.tableColumns.compactMap(dataColumn)
            if table.clickedColumn >= 0, let clicked = dataColumn(table.tableColumns[table.clickedColumn]),
               let at = order.firstIndex(of: clicked) {
                order.insert(order.remove(at: at), at: 0)
            }
            let linked = order.compactMap { column in
                data.columns[column].isLinked ? links.help(row, column).map { (column, $0) } : nil
            }
            if !linked.isEmpty {
                menu.addItem(.separator())
                for (column, help) in linked {
                    let item = NSMenuItem(title: help, action: #selector(followLink(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = column
                    item.representedObject = row
                    item.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: nil)
                    menu.addItem(item)
                    // Hold ⌥ for the same row in a new tab (S-037).
                    let tab = NSMenuItem(title: "\(help) in New Tab", action: #selector(followLinkInNewTab(_:)), keyEquivalent: "")
                    tab.target = self
                    tab.tag = column
                    tab.representedObject = row
                    tab.image = item.image
                    tab.isAlternate = true
                    tab.keyEquivalentModifierMask = .option
                    menu.addItem(tab)
                }
            }
        }
        if fieldEditor != nil, table.clickedRow >= 0 || table.selectedRow >= 0 {
            menu.addItem(.separator())
            item("Open in Field Editor", #selector(openClickedInFieldEditor), "rectangle.and.pencil.and.ellipsis")
        }
        if exportResults != nil {
            menu.addItem(.separator())
            item("Export Results…", #selector(exportAllResults), "square.and.arrow.up", enabled: !data.rows.isEmpty)
        }
        guard let rowActions else { return }
        menu.addItem(.separator())
        let noun = rowActions.noun
        if rowActions.edit != nil {
            item("Edit \(noun)…", #selector(editRow), "pencil", enabled: table.selectedRowIndexes.count == 1)
        }
        item("Add \(noun)" + (rowActions.addsWithSheet ? "…" : ""), #selector(addRow), "plus", enabled: rowActions.canAdd())
        if rowActions.duplicates {
            item("Duplicate \(noun)", #selector(duplicateRow), "plus.square.on.square", enabled: rowActions.canDuplicate())
        }
        let count = rowActions.deleteCount?() ?? table.selectedRowIndexes.count
        item(count > 1 ? "Delete \(count) \(rowActions.plural ?? noun + "s")…" : "Delete \(noun)…", #selector(deleteRows), "trash",
             enabled: rowActions.canDelete())
    }

    @objc func exportAllResults() {
        exportResults?()
    }

    @objc func editRow() {
        guard let table, table.selectedRow >= 0 else { return }
        rowActions?.edit?(table.selectedRow)
    }

    // MARK: Dragging rows (S-023)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let reorder, reorder.canDrag(row), active == nil else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .gridRow)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard reorder != nil, (info.draggingSource as? NSTableView) === tableView else { return [] }
        if operation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let reorder, let text = info.draggingPasteboard.string(forType: .gridRow), let source = Int(text) else { return false }
        reorder.move(source, row)
        return true
    }

    @objc func copyValues() { copy(.values) }
    @objc func copyWithNames() { copy(.withNames) }
    @objc func copyInsert() { copy(.insert) }
    @objc func addRow() { rowActions?.add() }
    @objc func openClickedInFieldEditor() {
        guard let table else { return }
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 else { return }
        let column = table.clickedColumn >= 0 ? dataColumn(table.tableColumns[table.clickedColumn]) : nil
        openFieldEditor(row: row, column: column)
    }
    @objc func duplicateRow() { rowActions?.duplicate() }
    @objc func followLink(_ item: NSMenuItem) {
        guard let row = item.representedObject as? Int else { return }
        links?.follow(row, item.tag, false)
    }
    @objc func followLinkInNewTab(_ item: NSMenuItem) {
        guard let row = item.representedObject as? Int else { return }
        links?.follow(row, item.tag, true)
    }
    @objc func deleteRows() { rowActions?.delete() }

    var canCopy: Bool { !(table?.selectedRowIndexes.isEmpty ?? true) }

    /// Puts the selected rows on the pasteboard, columns in on-screen order.
    func copy(_ style: CopyStyle) {
        guard let text = copyText(style) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyText(_ style: CopyStyle) -> String? {
        guard let table, !table.selectedRowIndexes.isEmpty else { return nil }
        let order = table.tableColumns.compactMap { tableColumn in
            data.columns.firstIndex { $0.id == tableColumn.identifier.rawValue }
        }
        let names = order.map { data.columns[$0].title }
        let rows = table.selectedRowIndexes.filter { $0 < data.rows.count }.map { row in
            order.map { $0 < data.rows[row].count ? data.rows[row][$0] : .null }
        }
        switch style {
        case .values: return RowCopy.tabSeparated(columns: names, rows: rows, names: false)
        case .withNames: return RowCopy.tabSeparated(columns: names, rows: rows, names: true)
        case .insert:
            guard let insertTable else { return nil }
            return RowCopy.insertStatement(table: insertTable.table, columns: names, rows: rows, engine: insertTable.engine)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table else { return }
        // Later: a reload inside a SwiftUI update can change the selection, and
        // the owner's state must not change during that update.
        let rows = table.selectedRowIndexes
        let report = reports.selection
        DispatchQueue.main.async { report(rows) }
    }
}

/// The Edit menu's copy commands and Set to NULL reach the focused grid through
/// the responder chain (a cell's editor passes them on to its table).
extension NSPasteboard.PasteboardType {
    /// A grid row being dragged within its own grid.
    static let gridRow = NSPasteboard.PasteboardType("com.quarry.grid-row")
}

@objc protocol GridCopying {
    func copyWithColumnNames(_ sender: Any?)
    func copyAsSQLInsert(_ sender: Any?)
    func setCellToNull(_ sender: Any?)
    func openInFieldEditor(_ sender: Any?)
}

extension GridTableView: GridCopying, NSMenuItemValidation {
    @objc func copy(_ sender: Any?) { rows?.copy(.values) }
    @objc func copyWithColumnNames(_ sender: Any?) { rows?.copy(.withNames) }
    @objc func copyAsSQLInsert(_ sender: Any?) { rows?.copy(.insert) }
    @objc func setCellToNull(_ sender: Any?) { rows?.setEditedCellToNull() }
    @objc func openInFieldEditor(_ sender: Any?) { rows?.openFieldEditor() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action.map(canPerform) ?? true
    }

    /// Whether the grid can do an Edit menu command now; the menu bar asks too (S-040).
    func canPerform(_ action: Selector) -> Bool {
        switch action {
        case #selector(copy(_:)), #selector(copyWithColumnNames(_:)): rows?.canCopy ?? false
        case #selector(copyAsSQLInsert(_:)): (rows?.canCopy ?? false) && rows?.insertTable != nil
        case #selector(setCellToNull(_:)): rows?.isEditingCell ?? false
        case #selector(openInFieldEditor(_:)): rows?.canOpenFieldEditor ?? false
        default: true
        }
    }
}
