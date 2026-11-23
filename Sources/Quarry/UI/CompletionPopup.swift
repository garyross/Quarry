import AppKit
import QuarryKit

/// The query editor's completion list (S-031): a floating menu-material panel
/// under the word being typed, with a symbol, the name and a dimmed detail
/// per row. It lives in a borderless child window that never takes focus, so
/// the editor keeps typing while the list follows (subviews added to
/// SwiftUI's hosting view do not draw).
@MainActor
final class CompletionPopup: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 22
    static let visibleRows = 8
    static let width: CGFloat = 360

    private let effect = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private(set) var list: CompletionList?
    /// Double-click on a row.
    var onAccept: ((Completion) -> Void)?

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = self
        return panel
    }()

    var isShowing: Bool { panel.isVisible && list != nil }
    var selected: Completion? {
        guard let list, table.selectedRow >= 0, table.selectedRow < list.items.count else { return nil }
        return list.items[table.selectedRow]
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .withinWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Radius.sm
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setAccessibilityLabel("Completions")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: Space.xs, left: 0, bottom: Space.xs, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.autoresizingMask = [.width, .height]
        effect.addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `list` under (or, near the screen's bottom, above) `anchor`, a rect in screen coordinates.
    func show(_ list: CompletionList, below anchor: NSRect, of window: NSWindow) {
        let keep = selected
        self.list = list
        table.reloadData()
        let rows = min(list.items.count, Self.visibleRows)
        let height = CGFloat(rows) * Self.rowHeight + 2 * Space.xs
        let width = Self.width
        let screen = window.screen?.visibleFrame ?? window.frame
        let x = min(max(anchor.minX - Space.xs, screen.minX), screen.maxX - width)
        let y = anchor.minY - height >= screen.minY ? anchor.minY - height : anchor.maxY
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        effect.frame = bounds
        scroll.frame = effect.bounds
        table.tableColumns.first?.width = width
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        // Keep the highlighted item while the list narrows, else the first.
        let index = keep.flatMap { list.items.firstIndex(of: $0) } ?? 0
        select(index)
        NSAccessibility.post(element: table, notification: .selectedRowsChanged)
    }

    func hide() {
        list = nil
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Up and Down move by one; Page Up and Page Down by a page. Stops at the ends.
    func move(by delta: Int) {
        guard let list, !list.items.isEmpty else { return }
        select(max(0, min(list.items.count - 1, table.selectedRow + delta)))
    }

    private func select(_ index: Int) {
        table.selectRowIndexes([index], byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    @objc private func doubleClicked() {
        if let selected { onAccept?(selected) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { list?.items.count ?? 0 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { EmphasizedRow() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = list?.items[row] else { return nil }
        let cell = (tableView.makeView(withIdentifier: CompletionCell.identifier, owner: nil) as? CompletionCell) ?? CompletionCell()
        cell.show(item)
        return cell
    }

    /// Selected rows draw in the accent color although the editor, not the list, has focus.
    private final class EmphasizedRow: NSTableRowView {
        override var isEmphasized: Bool { get { true } set {} }
    }
}

/// One row: the kind's symbol, the name in the editor's font, the detail dimmed.
private final class CompletionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("completion")
    private let symbol = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        symbol.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
        name.font = DataStyle.editorNSFont
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for view in [symbol, name, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = name
        imageView = symbol
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.sm),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: Space.lg),
            name.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: Space.xs),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: Space.sm),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.sm),
            detail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ item: Completion) {
        symbol.image = NSImage(systemSymbolName: Self.symbolName(item.kind), accessibilityDescription: item.detail)
        name.stringValue = item.name
        detail.stringValue = item.detail
        setAccessibilityLabel("\(item.name), \(item.detail)")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            detail.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            symbol.contentTintColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }

    static func symbolName(_ kind: Completion.Kind) -> String {
        switch kind {
        case .column: "list.bullet.rectangle"
        case .table: "tablecells"
        case .view: "eye"
        case .database: "cylinder"
        case .keyword: "textformat"
        case .function: "function"
        }
    }
}
