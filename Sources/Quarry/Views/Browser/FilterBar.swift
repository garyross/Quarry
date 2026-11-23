import QuarryKit
import QuarryControllers
import SwiftUI
import UniformTypeIdentifiers

/// Content's filter (S-014, S-015), above the grid, like Finder's search
/// criteria. "[All] of the following are true" always heads it; its + adds
/// the first rule, and it holds Saved Filters and Save… (S-062). Every line
/// ends with + (a rule below), − (remove; on the All line, every rule) and,
/// below the All line, ⇥ (a group below). Lines drag by their handle.
/// Rows filter as people type, after a pause; Return filters at once.
struct FilterBar: View {
    @Environment(Session.self) private var session
    @FocusState private var focusedRule: UUID?
    @State private var dropTarget: UUID?

    var body: some View {
        let content = session.content
        let rows = content.filter.draft.rows
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                line(row, content: content)
            }
        }
        .controlSize(.small)
        .font(.callout)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .disabled(content.filter.columns.isEmpty)
        .alert("Save Filter", isPresented: Binding(get: { content.filter.isNaming }, set: { content.filter.isNaming = $0 })) {
            @Bindable var content = content
            TextField("Name", text: Bindable(content.filter).name)
            Button("Save") { session.saveFilter(named: content.filter.name) }
                .disabled(content.filter.name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(saveMessage(content))
        }
        .onChange(of: focusedRule) { if let focusedRule { content.filter.focusedRuleID = focusedRule } }
        .onChange(of: content.filter.focus) {
            guard let rule = content.filter.focus?.rule else { return }
            // The new rule's field appears in this update; focus it on the next.
            Task { @MainActor in focusedRule = rule }
        }
    }

    private func line(_ row: FilterTree.Row, content: ContentController) -> some View {
        HStack(spacing: Space.sm) {
            handle(row)
            switch row.kind {
            case .header(let match, let isRoot):
                header(row.id, match: match, isRoot: isRoot, content: content)
            case .rule:
                RuleFields(rule: ruleBinding(row.id, content: content), columns: content.filter.columns,
                           focus: $focusedRule, id: row.id) { session.applyFilter() }
            }
            buttons(row, content: content)
        }
        .padding(.leading, Space.md + CGFloat(row.depth) * Space.xl)
        .padding(.trailing, Space.md)
        .padding(.vertical, Space.xs)
        .frame(minHeight: FilterLine.height)
        .contentShape(.rect)
        .dropDestination(for: FilterLineDrag.self) { items, _ in
            guard let item = items.first else { return false }
            return content.filter.move(item.id, below: row.id)
        } isTargeted: { targeted in
            if targeted { dropTarget = row.id } else if dropTarget == row.id { dropTarget = nil }
        }
        .overlay(alignment: .bottom) {
            // Where a dragged line lands: on the line below this one.
            if dropTarget == row.id {
                Rectangle().fill(.tint).frame(height: 2)
                    .padding(.leading, Space.md + CGFloat(row.depth + (row.isRule ? 0 : 1)) * Space.xl)
            }
        }
    }

    /// The drag handle; the All line has none but keeps the space, so its menu lines up.
    @ViewBuilder
    private func handle(_ row: FilterTree.Row) -> some View {
        let symbol = Image(systemName: "line.3.horizontal")
            .foregroundStyle(.tertiary)
            .frame(width: Space.md)
        if row.isRoot {
            symbol.hidden()
        } else {
            symbol
                .draggable(FilterLineDrag(id: row.id)) {
                    Label(row.isRule ? "Rule" : "Group", systemImage: "line.3.horizontal")
                        .padding(Space.xs)
                }
                .help("Drag to move this \(row.isRule ? "rule" : "group")")
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func header(_ id: UUID, match: FilterTree.Match, isRoot: Bool, content: ContentController) -> some View {
        Picker("Match", selection: Binding(get: { match }, set: { content.filter.draft.setMatch(id, $0) })) {
            ForEach(FilterTree.Match.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .help("All: every rule must match. Any: at least one. None: no rule may match.")
        .accessibilityLabel(isRoot ? "Match" : "Group match")
        Text("of the following are true")
            .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if isRoot {
            savedFiltersMenu(content)
            Button("Save…") { session.requestSaveFilter() }
                .disabled(!content.filter.canSave)
                .help("Save this filter on \(session.selectedObject?.name ?? "this table"), empty values too (⌥⌘S)")
        }
    }

    /// The table's saved filters: choosing one filters at once.
    private func savedFiltersMenu(_ content: ContentController) -> some View {
        let saved = session.savedFilters
        return Menu("Saved Filters") {
            ForEach(saved, id: \.uid) { filter in
                Button(filter.name) { session.openSavedFilter(filter.uid) }
            }
            if !saved.isEmpty {
                Divider()
                Menu("Delete") {
                    ForEach(saved, id: \.uid) { filter in
                        Button(filter.name, role: .destructive) { session.deleteSavedFilter(filter.uid) }
                    }
                }
            }
        }
        .fixedSize()
        .disabled(saved.isEmpty)
        .help(saved.isEmpty ? "Filters you save on this table show here" : "Open a filter saved on this table")
    }

    private func saveMessage(_ content: ContentController) -> String {
        let table = session.selectedObject?.name ?? "this table"
        let exists = session.savedFilters.contains { $0.name == content.filter.name.trimmingCharacters(in: .whitespaces) }
        return exists ? "Replaces the filter with this name on \(table)."
            : "Saved on \(table). Rules with no value are kept, to fill in when you open it."
    }

    /// + − ⇥ on every line, so they line up down the list.
    private func buttons(_ row: FilterTree.Row, content: ContentController) -> some View {
        let removeHelp = row.isRoot ? "Remove every rule" : row.isRule ? "Remove this rule" : "Remove this group and its rules"
        return HStack(spacing: Space.xs) {
            Button("Add Rule", systemImage: "plus") { content.filter.addRule(below: row.id) }
                .help("Add a rule below this line (⇧⌘F)")
            Button("Remove", systemImage: "minus") { content.filter.remove(row.id) }
                .help(removeHelp)
                .disabled(row.isRoot && content.filter.draft.isEmpty)
            // The All line has no ⇥ (a group needs a rule first), but keeps the slot so the buttons line up.
            Button("Add Group", systemImage: "increase.indent") { content.filter.addGroup(below: row.id) }
                .help("Add a group of rules below this line (⌥⇧⌘F)")
                .opacity(row.isRoot ? 0 : 1)
                .disabled(row.isRoot)
                .accessibilityHidden(row.isRoot)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
    }

    private func ruleBinding(_ id: UUID, content: ContentController) -> Binding<RowFilter> {
        Binding(get: { content.filter.draft.rule(id) ?? RowFilter(column: "") },
                set: { content.filter.draft.setRule(id, $0) })
    }
}

enum FilterLine {
    /// One line of the filter: a small control with room around it.
    static let height: CGFloat = 32
}

/// What a dragged filter line carries: its id, as Quarry's own type, so text
/// fields don't take it as text.
nonisolated struct FilterLineDrag: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .quarryFilterLine)
    }
}

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations).
    nonisolated static let quarryFilterLine = UTType(exportedAs: "app.quarry.filter-line")
}

/// One rule: column, operator, and the value fields the operator needs. The
/// column menu ends with WHERE Clause (S-061), like Finder's Raw Query: the
/// rule's one field then takes SQL, and filters on Return.
private struct RuleFields: View {
    @Binding var rule: RowFilter
    let columns: [String]
    var focus: FocusState<UUID?>.Binding
    let id: UUID
    let submit: () -> Void

    /// The column menu's choice: a column, or a WHERE clause typed as SQL.
    private enum Choice: Hashable {
        case column(String)
        case typed
    }

    private var choice: Binding<Choice> {
        Binding(get: { rule.op == .sql ? .typed : .column(rule.column) },
                set: { choice in
                    switch choice {
                    case .typed:
                        rule.op = .sql
                        rule.value = ""
                    case .column(let name):
                        if rule.op == .sql { rule.op = .equals; rule.value = "" }
                        rule.column = name
                    }
                })
    }

    var body: some View {
        Picker("Column", selection: choice) {
            ForEach(columns, id: \.self) { Text($0).tag(Choice.column($0)) }
            Divider()
            Text("WHERE Clause").tag(Choice.typed)
        }
        .labelsHidden()
        .fixedSize()
        .help("The column to filter on, or WHERE Clause to type a condition in SQL (⌃⌥⌘F)")
        .accessibilityLabel("Filter column")

        if rule.op == .sql {
            TextField(rule.op.placeholder, text: $rule.value)
                .font(DataStyle.gridFont)
                .focused(focus, equals: id)
                .onSubmit(submit)
                .frame(minWidth: FilterLine.valueWidth)
                .help("A condition in SQL, as after WHERE. Press Return to filter.")
                .accessibilityLabel("WHERE clause")
        } else {
            comparison
        }
        Spacer(minLength: 0)
    }

    @ViewBuilder
    private var comparison: some View {
        Picker("Operator", selection: $rule.op) {
            ForEach(RowFilter.Operator.comparisons) { op in
                if op.startsGroup { Divider() }
                Text(op.title).tag(op)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("How the column is compared with the value")
        .accessibilityLabel("Filter operator")

        if rule.op.valueCount > 0 {
            TextField(rule.op.placeholder, text: $rule.value)
                .focused(focus, equals: id)
                .onSubmit(submit)
                .frame(minWidth: 120, maxWidth: FilterLine.valueWidth)
                .help(rule.op == .isIn ? "Values separated by commas. Rows filter as you type." : "Rows filter as you type.")
                .accessibilityLabel(rule.op == .between ? "From" : "Filter value")
        }
        if rule.op.valueCount > 1 {
            Text("and").foregroundStyle(.secondary)
            TextField("to", text: $rule.secondValue)
                .onSubmit(submit)
                .frame(minWidth: 120, maxWidth: FilterLine.valueWidth)
                .accessibilityLabel("To")
        }
    }
}

extension FilterLine {
    /// Value fields stop growing here, like Finder's, so + − ⇥ stay at the far edge.
    static let valueWidth: CGFloat = 320
}
