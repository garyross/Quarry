import AppKit
import QuarryKit
import QuarryControllers
import SwiftUI

/// A grid of database values.
///
/// AppKit's NSTableView, not SwiftUI's Table: results have columns known only
/// at run time, often thousands of rows and dozens of columns, and need
/// resizable, reorderable columns. NSTableView is Apple's own control and
/// keeps the native look (docs/DESIGN.md §7).
struct DataGrid: NSViewRepresentable {
    let data: GridData
    /// The header showing the sort arrow: (sortKey, ascending).
    var sort: (key: String, ascending: Bool)?
    /// Called when people click a sortable header.
    var onSort: ((String, Bool) -> Void)?
    /// Inline editing (S-009). Nil makes the grid read-only.
    var editing: Editing?
    /// Add, duplicate and delete rows (S-010). Nil hides them.
    var rowActions: RowActions?
    /// The table Copy as SQL INSERT names, and the engine its values are quoted for;
    /// nil leaves that command out.
    var insertTable: InsertTarget?
    /// "Export Results…" at the end of the row menu (S-042); nil leaves it out.
    var exportResults: (() -> Void)?
    var reports = Reports()
    /// Long values open in the Field Editor (S-012). Nil keeps every cell inline.
    var fieldEditor: FieldEditorHook?
    /// Foreign-key arrows (S-017). Nil draws none.
    var links: LinkHook?
    /// Starts editing this cell once; a new `id` asks again.
    var editRequest: (row: Int, column: Int, id: UUID)?
    /// Selects this row once; a new `id` asks again.
    var selectRequest: (row: Int, id: UUID)?
    /// Dragging rows to reorder them. Nil keeps rows in place.
    var reorder: RowReorder?
    var accessibilityLabel = "Rows"

    /// What an editable grid asks its owner. Column indexes are `data.columns` indexes.
    struct Editing {
        var canEdit: (_ row: Int, _ column: Int) -> Bool
        /// The text a cell's editor starts with ("" for NULL).
        var text: (_ row: Int, _ column: Int) -> String
        /// Called when people end an edit with a changed value: the typed text, or NULL (⌃⇧N, S-011).
        var save: (_ row: Int, _ column: Int, _ value: CellValue) -> Void
        /// Called when editing leaves the row (Return, clicking away, Escape), not when Tab moves along it.
        var endRow: (_ row: Int, _ cancelled: Bool) -> Void = { _, _ in }
    }

    /// Which cells open the Field Editor, and how to open it. `typed` carries an inline edit over.
    struct FieldEditorHook {
        var opens: (_ row: Int, _ column: Int) -> Bool
        var open: (_ row: Int, _ column: Int, _ typed: String?) -> Void
    }

    /// Which cells link to a referenced row, their help, and following one.
    struct LinkHook {
        var help: (_ row: Int, _ column: Int) -> String?
        /// `newTab` for ⌘-click (S-037).
        var follow: (_ row: Int, _ column: Int, _ newTab: Bool) -> Void
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator, accessibilityLabel: accessibilityLabel)
    }

    /// The table in its scroll view. The self-test builds one off screen.
    static func makeScrollView(coordinator: Coordinator, accessibilityLabel: String) -> NSScrollView {
        let table = GridTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        Coordinator.applyStyle(to: table)
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.onReturn = { [weak coordinator] in coordinator?.editSelectedRow() ?? false }
        table.onDelete = { [weak coordinator] in
            guard let actions = coordinator?.rowActions, actions.canDelete() else { return false }
            actions.delete()
            return true
        }
        table.onFocus = { [weak coordinator] in coordinator?.reports.focus($0) }
        table.rows = coordinator
        table.menu = coordinator.makeRowMenu()
        table.registerForDraggedTypes([.gridRow])
        table.draggingDestinationFeedbackStyle = .gap
        table.setAccessibilityLabel(accessibilityLabel)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        coordinator.table = table
        coordinator.followPreferences()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSort = onSort
        coordinator.editing = editing
        coordinator.rowActions = rowActions
        coordinator.insertTable = insertTable
        coordinator.exportResults = exportResults
        coordinator.fieldEditor = fieldEditor
        coordinator.links = links
        coordinator.reorder = reorder
        coordinator.reports = reports
        guard let table = coordinator.table else { return }
        if coordinator.data.revision != data.revision {
            let columnsChanged = coordinator.data.columns.map(\.title) != data.columns.map(\.title)
                || coordinator.data.columns.map(\.help) != data.columns.map(\.help)
            coordinator.data = data
            if columnsChanged { coordinator.rebuildColumns() }
            table.reloadData()
            if columnsChanged { table.scrollRowToVisible(0) }
        }
        coordinator.applySort(sort)
        if let request = editRequest, request.id != coordinator.handledRequest {
            coordinator.handledRequest = request.id
            // After this update, so the table has laid out a row it just gained.
            DispatchQueue.main.async { coordinator.beginEditing(row: request.row, column: request.column) }
        }
        if let request = selectRequest, request.id != coordinator.handledSelect {
            coordinator.handledSelect = request.id
            if request.row < table.numberOfRows {
                table.selectRowIndexes(IndexSet(integer: request.row), byExtendingSelection: false)
                table.scrollRowToVisible(request.row)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        weak var table: NSTableView?
        var data = GridData.empty
        var onSort: ((String, Bool) -> Void)?
        var editing: Editing?
        var rowActions: RowActions?
        var insertTable: InsertTarget?
        var exportResults: (() -> Void)?
        var fieldEditor: FieldEditorHook?
        var links: LinkHook?
        var reports = Reports()
        var handledRequest: UUID?
        var handledSelect: UUID?
        var reorder: RowReorder?
        /// The grid settings last applied (S-054), so other defaults changes redraw nothing.
        private var style = GridStyle.current
        nonisolated(unsafe) private var preferencesObserver: NSObjectProtocol?

        deinit {
            if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        }

        /// Settings > Tables: row height and grid lines from the font and the toggle.
        static func applyStyle(to table: NSTableView) {
            GridCellView.useCurrentFont()
            table.rowHeight = (DataStyle.gridSize + 8).rounded()
            table.gridStyleMask = Preferences.gridLines ? [.solidVerticalGridLineMask] : []
        }

        /// Redraws when Settings changes the font, NULL text or grid lines.
        func followPreferences() {
            preferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.preferencesChanged() }
            }
        }

        private func preferencesChanged() {
            let now = GridStyle.current
            guard now != style, let table else { return }
            let fontChanged = now.font != style.font
            style = now
            Self.applyStyle(to: table)
            if fontChanged, active == nil { rebuildColumns() }
            table.reloadData()
        }

        /// True while Tab moves editing to the next cell, so the row is not finished.
        private var continuing = false
        /// The cell being edited: data row and column, and the text it started with.
        private(set) var active: (row: Int, column: Int, original: String, field: NSTextField)?
        private var cancelled = false
        /// Set to NULL (⌃⇧N) ends the edit with NULL instead of the typed text.
        private var settingNull = false
        private var applyingSort = false
        private let cellID = NSUserInterfaceItemIdentifier("cell")

        func rebuildColumns() {
            guard let table else { return }
            for column in table.tableColumns { table.removeTableColumn(column) }
            let font = DataStyle.gridNSFont
            let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
            let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            for (index, column) in data.columns.enumerated() {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
                tableColumn.title = column.title
                tableColumn.headerToolTip = column.help.map { column.title + "\n" + $0 } ?? column.title
                if let key = column.sortKey {
                    tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
                }
                // Size to the header and the first rows' values, within the token limits.
                let header = (column.title as NSString).size(withAttributes: [.font: headerFont]).width + 24
                let longest = data.rows.prefix(100).map { $0[index].displayText.count }.max() ?? 0
                // A linked column (S-017) also holds its arrow.
                let arrow: CGFloat = column.isLinked ? 18 : 0
                let width = max(header, CGFloat(min(longest, 60)) * digit + 12 + arrow)
                tableColumn.width = min(Layout.gridColumnMax, max(Layout.gridColumnMin, width.rounded()))
                tableColumn.minWidth = Layout.gridColumnMin
                table.addTableColumn(tableColumn)
            }
        }

        func applySort(_ sort: (key: String, ascending: Bool)?) {
            guard let table else { return }
            let wanted = sort.map { [NSSortDescriptor(key: $0.key, ascending: $0.ascending)] } ?? []
            guard table.sortDescriptors != wanted else { return }
            applyingSort = true
            table.sortDescriptors = wanted
            applyingSort = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int { data.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = data.columns.firstIndex(where: { $0.id == tableColumn.identifier.rawValue }),
                  row < data.rows.count, index < data.rows[row].count else { return nil }
            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? GridCellView) ?? makeCell()
            let value = data.rows[row][index]
            var alignment: NSTextAlignment = data.columns[index].isNumeric ? .right : .natural
            let color: NSColor
            var spoken: String?
            let text = value.displayText
            var shown = text
            switch value {
            case .null:
                color = DataStyle.nullColor
                shown = DataStyle.nullText
            case .binary(let bytes):
                if let width = data.columns[index].bitWidth {
                    // A BIT value reads as its bits, like the server's b'00000101' (S-013).
                    shown = BitValue(width: width, data: bytes).bits
                    color = .labelColor
                } else {
                    color = DataStyle.placeholderColor
                }
            case .flag(let on):
                alignment = .center
                color = .labelColor
                shown = on ? "✓" : ""
                spoken = on ? "Yes" : "No"
            case .text:
                color = .labelColor
            }
            cell.show(shown, color: color, alignment: alignment, spoken: spoken)
            cell.toolTip = shown.count > 40 ? String(shown.prefix(2000))
                : data.columns[index].affinity?.storedNote(value) ?? data.columns[index].help
            if data.columns[index].isLinked, let links, let help = links.help(row, index) {
                cell.showLink(help: help) { [weak self, weak cell] newTab in
                    // The row the cell shows now: rows move when the table scrolls.
                    guard let self, let cell, let table = self.table else { return }
                    let shownRow = table.row(for: cell)
                    if shownRow >= 0 { self.links?.follow(shownRow, index, newTab) }
                }
            } else {
                cell.hideLink()
            }
            return cell
        }

        private func makeCell() -> GridCellView {
            let cell = GridCellView(frame: NSRect(x: 0, y: 0, width: 100, height: table?.rowHeight ?? 24))
            cell.identifier = cellID
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applyingSort, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            onSort?(key, descriptor.ascending)
        }

        // MARK: Editing

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            let column = sender.clickedColumn
            guard row >= 0, column >= 0, let index = dataColumn(sender.tableColumns[column]) else { return }
            if let fieldEditor, fieldEditor.opens(row, index) {
                fieldEditor.open(row, index, nil)
            } else if let edit = rowActions?.edit, !(editing?.canEdit(row, index) ?? false) {
                edit(row)
            } else {
                beginEditing(row: row, column: index)
            }
        }

        var canOpenFieldEditor: Bool { fieldEditor != nil && (active != nil || (table?.selectedRow ?? -1) >= 0) }

        /// Open in Field Editor (⌃⌘E): the cell being edited, with what was typed;
        /// else the selected row's first long value, else its first cell.
        func openFieldEditor(row: Int? = nil, column: Int? = nil) {
            guard let table, let fieldEditor else { return }
            if let active {
                let typed = active.field.stringValue
                // Ends the inline edit without saving, and without ending the row.
                cancelled = true
                continuing = true
                table.window?.makeFirstResponder(table)
                continuing = false
                fieldEditor.open(active.row, active.column, typed == active.original ? nil : typed)
                return
            }
            let row = row ?? table.selectedRow
            guard row >= 0, row < data.rows.count else { return }
            let order = table.tableColumns.compactMap(dataColumn)
            guard let column = column ?? order.first(where: { fieldEditor.opens(row, $0) }) ?? order.first else { return }
            fieldEditor.open(row, column, nil)
        }

        /// Return on a selected row edits its first editable cell, left to right on screen.
        /// Returns false when there is nothing to edit, so the key goes on to the table.
        func editSelectedRow() -> Bool {
            guard let table, table.selectedRow >= 0, let editing else { return false }
            let row = table.selectedRow
            guard let index = table.tableColumns.compactMap(dataColumn).first(where: { editing.canEdit(row, $0) }) else { return false }
            return beginEditing(row: row, column: index)
        }

        /// Puts the cell's text field into editing with the value's text selected.
        @discardableResult
        func beginEditing(row: Int, column: Int) -> Bool {
            guard let table, let editing, editing.canEdit(row, column),
                  let tableColumn = table.tableColumns.firstIndex(where: { dataColumn($0) == column }) else { return false }
            table.scrollRowToVisible(row)
            table.scrollColumnToVisible(tableColumn)
            guard let cell = table.view(atColumn: tableColumn, row: row, makeIfNecessary: true) as? GridCellView else { return false }
            let field = cell.beginEditingField()
            let text = editing.text(row, column)
            field.isEditable = true
            field.isSelectable = true
            field.delegate = self
            field.stringValue = text
            field.textColor = .labelColor
            field.alignment = .natural
            field.lineBreakMode = .byClipping
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            active = (row, column, text, field)
            cancelled = false
            settingNull = false
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
            return true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let active else { return false }
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                cancelled = true
                table?.window?.makeFirstResponder(table)
                return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                let forward = selector == #selector(NSResponder.insertTab(_:))
                let next = nextEditable(row: active.row, after: active.column, forward: forward)
                continuing = next != nil
                table?.window?.makeFirstResponder(table)
                continuing = false
                if let next { beginEditing(row: active.row, column: next) }
                return true
            case #selector(NSResponder.insertNewline(_:)):
                table?.window?.makeFirstResponder(table)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let active, (notification.object as? NSTextField) === active.field else { return }
            self.active = nil
            let field = active.field
            field.isEditable = false
            field.isSelectable = false
            field.delegate = nil
            let text = field.stringValue
            (field.superview as? GridCellView)?.endEditingField()
            let wasCancelled = cancelled
            if !cancelled, active.row < data.rows.count {
                if settingNull {
                    if !data.rows[active.row][active.column].isNull {
                        data.rows[active.row][active.column] = .null
                        editing?.save(active.row, active.column, .null)
                    }
                } else if text != active.original {
                    data.rows[active.row][active.column] = .text(text)
                    editing?.save(active.row, active.column, .text(text))
                }
            }
            cancelled = false
            settingNull = false
            // Redraw the cell from the data: NULL styling, alignment, truncation.
            if let table, let tableColumn = table.tableColumns.firstIndex(where: { dataColumn($0) == active.column }),
               active.row < table.numberOfRows {
                table.reloadData(forRowIndexes: IndexSet(integer: active.row), columnIndexes: IndexSet(integer: tableColumn))
            }
            if !continuing { editing?.endRow(active.row, wasCancelled) }
        }

        /// True while a cell is being edited, so Set to NULL applies.
        var isEditingCell: Bool { active != nil }

        /// Set to NULL (⌃⇧N, S-011): ends the edit and saves NULL, as Return saves text.
        func setEditedCellToNull() {
            guard active != nil else { return }
            settingNull = true
            table?.window?.makeFirstResponder(table)
        }

        /// Tab and Shift-Tab: the next editable cell in the row, in on-screen order.
        private func nextEditable(row: Int, after column: Int, forward: Bool) -> Int? {
            guard let table, let editing else { return nil }
            var order = table.tableColumns.compactMap(dataColumn)
            if !forward { order.reverse() }
            guard let start = order.firstIndex(of: column) else { return nil }
            return order[(start + 1)...].first { editing.canEdit(row, $0) }
        }

        func dataColumn(_ tableColumn: NSTableColumn) -> Int? {
            data.columns.firstIndex { $0.id == tableColumn.identifier.rawValue }
        }
    }
}

/// One grid cell. It draws its value with a shared NSTextFieldCell, so it
/// looks like a label without being one: a page shows hundreds of cells, and
/// a text field per cell made the table the slowest part of showing a page
/// (docs/FIXLOG.md). Editing adds a real text field over it, made the first
/// time the cell is edited.
final class GridCellView: NSTableCellView {
    private var text = ""
    private var color = NSColor.labelColor
    private var alignment = NSTextAlignment.natural
    private var spoken: String?
    /// The foreign-key arrow's action and help (S-017); nil draws no arrow.
    private var follow: ((_ newTab: Bool) -> Void)?
    private var linkHelp: String?

    /// Shared by every cell: drawing happens on the main thread, one cell at a time.
    /// Picks up Settings > Tables' font (S-054) for every cell.
    @MainActor static func useCurrentFont() {
        let font = DataStyle.gridNSFont
        guard drawer.font != font else { return }
        drawer.font = font
        lineHeight = drawer.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1000, height: 1000)).height.rounded(.up)
    }

    @MainActor private static let drawer: NSTextFieldCell = {
        let cell = NSTextFieldCell(textCell: "")
        cell.font = DataStyle.gridNSFont
        cell.lineBreakMode = .byTruncatingTail
        cell.truncatesLastVisibleLine = true
        cell.isEditable = false
        cell.isBordered = false
        cell.drawsBackground = false
        return cell
    }()

    /// One line of the grid font, measured once.
    @MainActor private static var lineHeight: CGFloat = drawer.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1000, height: 1000)).height.rounded(.up)

    /// The value's text as it shows in the cell; the self-test reads it.
    var shownText: String { text }

    override var isFlipped: Bool { true }

    func show(_ text: String, color: NSColor, alignment: NSTextAlignment, spoken: String?) {
        self.text = text
        self.color = color
        self.alignment = alignment
        self.spoken = spoken
        needsDisplay = true
    }

    func showLink(help: String, follow: @escaping (_ newTab: Bool) -> Void) {
        self.follow = follow
        if linkHelp != help {
            linkHelp = help
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
        if toolTip == nil { toolTip = "\(help) (⌘-click for a new tab)" }
    }

    func hideLink() {
        guard follow != nil || linkHelp != nil else { return }
        follow = nil
        linkHelp = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    var hasLink: Bool { follow != nil }

    /// Where the label sits: inset 2 pt, one line high, centered in the row,
    /// short of the arrow when there is one.
    private var labelFrame: NSRect {
        let height = Self.lineHeight
        let arrow = follow == nil ? 0 : Self.arrowSize + 4
        return NSRect(x: 2, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - 4 - arrow), height: height)
    }

    @MainActor private static let arrowSize: CGFloat = 14

    /// The arrow at the trailing edge, centered in the row.
    private var arrowFrame: NSRect {
        let size = Self.arrowSize
        let x = userInterfaceLayoutDirection == .rightToLeft ? 2 : bounds.width - size - 2
        return NSRect(x: x, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
    }

    /// "arrow.right.circle.fill" in the grid's text size, like Sequel Pro's link arrow.
    @MainActor private static func arrowImage(_ color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: arrowSize - 2, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: "Open referenced row")?
            .withSymbolConfiguration(configuration)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if follow != nil { addCursorRect(arrowFrame, cursor: .pointingHand) }
    }

    /// Follows the link when a single click lands on the arrow. NSTableView
    /// keeps mouse-downs from cell views that are not controls, so
    /// GridTableView asks here (docs/FIXLOG.md).
    /// ⌘-click opens the referenced row in a new tab (S-037).
    func followLinkIfArrow(at windowPoint: NSPoint, clickCount: Int, newTab: Bool) -> Bool {
        guard let follow, clickCount == 1,
              arrowFrame.insetBy(dx: -2, dy: -2).contains(convert(windowPoint, from: nil)) else { return false }
        follow(newTab)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard textField?.isHidden ?? true else { return }
        let cell = Self.drawer
        cell.stringValue = text
        cell.textColor = color
        cell.alignment = alignment
        // White on a selected row, like a label in a cell view.
        cell.backgroundStyle = backgroundStyle
        cell.draw(withFrame: labelFrame, in: self)
        if follow != nil {
            let color: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            Self.arrowImage(color)?.draw(in: arrowFrame)
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    /// The text field editing uses, made the first time and shown over the drawing.
    func beginEditingField() -> NSTextField {
        let field = textField ?? {
            let field = NSTextField(labelWithString: "")
            field.font = DataStyle.gridNSFont
            field.maximumNumberOfLines = 1
            field.autoresizingMask = [.width, .minYMargin, .maxYMargin]
            addSubview(field)
            textField = field
            return field
        }()
        field.frame = labelFrame
        field.isHidden = false
        needsDisplay = true
        return field
    }

    /// Hides the editing field; the cell draws its value again.
    func endEditingField() {
        guard let field = textField else { return }
        field.isEditable = false
        field.isSelectable = false
        field.delegate = nil
        field.drawsBackground = false
        field.isHidden = true
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
    override func accessibilityValueDescription() -> String? { spoken }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let follow, let linkHelp else { return nil }
        return [NSAccessibilityCustomAction(name: linkHelp) { follow(false); return true },
                NSAccessibilityCustomAction(name: "\(linkHelp) in a new tab") { follow(true); return true }]
    }
}

/// NSTableView that reports Return (edit the row), Delete (delete rows) and its focus.
final class GridTableView: NSTableView {
    /// Return true when they handled the key.
    var onReturn: (() -> Bool)?
    var onDelete: (() -> Bool)?
    var onFocus: ((Bool) -> Void)?
    /// Copy and the row menu (DataGrid+Rows.swift).
    weak var rows: DataGrid.Coordinator?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if [36, 76].contains(event.keyCode), modifiers.isEmpty, onReturn?() == true { return }
        // ⌫ and ⌦, alone or with ⌘.
        if [51, 117].contains(event.keyCode), modifiers.isEmpty || modifiers == .command, onDelete?() == true { return }
        super.keyDown(with: event)
    }

    /// A click on a foreign-key arrow follows it; anywhere else selects as usual.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        if row >= 0, column >= 0,
           let cell = view(atColumn: column, row: row, makeIfNecessary: false) as? GridCellView,
           cell.followLinkIfArrow(at: event.locationInWindow, clickCount: event.clickCount,
                                  newTab: event.modifierFlags.contains(.command)) {
            return
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }
}

/// The grid settings that change how cells draw (S-054).
struct GridStyle: Equatable {
    var font: NSFont
    var nullText: String
    var lines: Bool

    @MainActor static var current: GridStyle {
        GridStyle(font: DataStyle.gridNSFont, nullText: DataStyle.nullText, lines: Preferences.gridLines)
    }
}

extension DataGrid {
    /// Where Copy as SQL INSERT points: the table it names and the engine whose quoting its values use.
    struct InsertTarget: Equatable {
        var table: String
        var engine: Engine
    }
}
