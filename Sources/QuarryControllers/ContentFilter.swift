import Foundation
import Observation
import QuarryKit

/// Content's filter (S-014, S-015, S-061, S-062): rules in groups under "All of the
/// following", the WHERE clause the page was loaded with, the search that waits
/// for typing to pause, and saved filters. Owned by `ContentController`, which
/// tells it the shown table (`show`, `tableLoaded`) and runs its searches
/// (`search`): the first page under `appliedClause`.
@Observable
package final class ContentFilter {
    /// The rules as edited. Every change searches after a pause (`FilterDefaults.delay`);
    /// Return searches at once. Typing a WHERE clause (S-061) waits for Return: half a clause is an error.
    package var draft = FilterTree() {
        didSet {
            guard draft != oldValue else { return }
            if draft.typedClauses != oldValue.typedClauses {
                pending?.cancel()
                pending = nil
            } else {
                schedule()
            }
        }
    }
    /// The WHERE clause the page was loaded with; nil shows every row.
    package private(set) var appliedClause: String?
    /// Asks a rule's value field to take focus (⌘F, a new rule); a new `id` each time.
    package private(set) var focus: Focus?
    /// The rule whose field has focus, so the Table menu's Add and Group act on it.
    package var focusedRuleID: UUID?
    /// The saved filter last opened or saved here: Save offers its name (S-062).
    package private(set) var savedName: String?
    /// True while the Save Filter alert asks for a name.
    package var isNaming = false
    /// The name typed in the Save Filter alert.
    package var name = ""
    /// The rules' column choices: the shown table's columns.
    package private(set) var columns: [String] = []

    package struct Focus: Equatable {
        package let rule: UUID
        package let id = UUID()
    }

    /// The search that waits for typing to pause.
    @ObservationIgnored package private(set) var pending: Task<Void, Never>?
    /// The shown table's engine, for quoting the clause; nil with no table shown.
    @ObservationIgnored private var engine: Engine?
    /// The shown table's fields: new rules start on its auto-increment or an indexed column.
    @ObservationIgnored private var fields: [FieldInfo] = []
    /// Shows the first page under `appliedClause`: ContentController's reload.
    @ObservationIgnored package var search: (() -> Task<Void, Never>?)?

    // MARK: The shown table

    /// A table is shown on `engine`'s connection (nil: none).
    package func show(engine: Engine?) { self.engine = engine }

    /// The page loaded: its columns and the table's fields. Rules on columns it no longer has go.
    package func tableLoaded(columns: [String], fields: [FieldInfo]) {
        self.columns = columns
        self.fields = fields
        if !draft.columns.isSubset(of: columns) { draft = FilterTree() }
    }

    /// Another table, a new database or a disconnect: no rules, every row.
    package func reset() {
        appliedClause = nil
        draft = FilterTree()
        savedName = nil
        isNaming = false
        pending?.cancel()
        pending = nil
        focusedRuleID = nil
        fields = []
    }

    /// A new database or a disconnect: no table, no columns, no rules.
    package func detach() {
        reset()
        engine = nil
        columns = []
    }

    /// Back or a followed link (S-017): the rules and clause the table had.
    package func restore(_ tree: FilterTree, clause: String?, savedName: String?) {
        reset()
        // The clause first, so setting the rules does not schedule a search of its own.
        appliedClause = clause
        draft = tree
        pending?.cancel()
        pending = nil
        self.savedName = savedName
    }

    // MARK: Searching

    package var isFiltered: Bool { appliedClause != nil }

    package var canEdit: Bool { engine != nil && !columns.isEmpty }

    /// Columns with an index (first in it): rules on them search sooner.
    private var indexedColumns: Set<String> {
        Set(fields.filter { !$0.key.isEmpty }.map(\.name))
    }

    /// A new rule: the auto-increment column, else a unique or indexed one, "=", no value yet.
    private var newRule: RowFilter {
        RowFilter(column: FilterDefaults.column(fields) ?? columns.first ?? "")
    }

    /// After an edit to the rules: search once typing pauses, unless the
    /// clause is unchanged (a rule with no value yet changes nothing).
    private func schedule() {
        pending?.cancel()
        pending = nil
        guard let engine, draft.whereClause(engine: engine) != appliedClause else { return }
        let delay = FilterDefaults.delay(for: draft.activeRules, indexed: indexedColumns)
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.apply()?.value
        }
    }

    /// Searches now (Return in a value field): the first page of matching rows.
    @discardableResult
    package func apply() -> Task<Void, Never>? {
        pending?.cancel()
        pending = nil
        guard let engine else { return nil }
        appliedClause = draft.whereClause(engine: engine)
        return search?()
    }

    /// Clear Filter, and − on the All line: every rule goes, every row shows.
    @discardableResult
    package func clear() -> Task<Void, Never>? {
        draft.remove(draft.root.id)
        focusedRuleID = nil
        savedName = nil
        guard isFiltered else { return nil }
        return apply()
    }

    // MARK: Editing the rules

    /// ⌘F: the focused rule's value field, or the first rule's; a first rule when there is none.
    package func requestFocus() {
        guard canEdit else { return }
        if let rule = focusedRuleID.flatMap({ id in draft.rule(id).map { _ in id } }) ?? draft.rules.first?.id {
            focus = Focus(rule: rule)
        } else {
            addRule(below: draft.root.id)
        }
    }

    /// Where a new line goes: below `id`, the focused rule, the last rule, or the All line.
    private func anchor(_ id: UUID?) -> UUID {
        id ?? focusedRuleID.flatMap { draft.contains($0) ? $0 : nil } ?? draft.rules.last?.id ?? draft.root.id
    }

    /// + : a new rule on the line below `id`, or below the focused rule.
    package func addRule(below id: UUID? = nil) {
        guard canEdit else { return }
        focus = Focus(rule: draft.add(newRule, below: anchor(id)))
    }

    /// Table > Add WHERE Clause (S-061): a rule people type as SQL, below the focused rule.
    package func addTypedClause(below id: UUID? = nil) {
        guard canEdit else { return }
        var rule = newRule
        rule.op = .sql
        focus = Focus(rule: draft.add(rule, below: anchor(id)))
    }

    /// ⇥ : a new group with one rule on the line below `id`, or below the focused rule.
    package func addGroup(below id: UUID? = nil) {
        guard canEdit else { return }
        focus = Focus(rule: draft.addGroup(newRule, below: anchor(id)))
    }

    /// − : a rule, a group, or (on the All line) every rule, which reloads at once.
    @discardableResult
    package func remove(_ id: UUID) -> Task<Void, Never>? {
        if id == draft.root.id { return clear() }
        draft.remove(id)
        if focusedRuleID.map({ !draft.contains($0) }) ?? false { focusedRuleID = nil }
        return nil
    }

    /// Drag and drop: `id` onto the line `target`.
    @discardableResult
    package func move(_ id: UUID, below target: UUID) -> Bool {
        draft.move(id, below: target)
    }

    // MARK: Saved filters (S-062)

    package var canSave: Bool { canEdit && !draft.isEmpty }

    /// Save Filter…: asks for a name, offering the opened filter's.
    package func requestSave() {
        guard canSave else { return }
        name = savedName ?? ""
        isNaming = true
    }

    package func didSave(as name: String) { savedName = name }

    /// Opens a saved filter: it filters at once, and the cursor goes to the first rule
    /// still waiting for a value. Throws when it names a column the table no longer has.
    @discardableResult
    package func open(_ tree: FilterTree, named name: String) throws -> Task<Void, Never>? {
        let missing = tree.columns.subtracting(columns)
        guard canEdit, missing.isEmpty else {
            throw DatabaseError(message: "The filter \u{201C}\(name)\u{201D} names columns this table doesn't have: "
                                + missing.sorted().joined(separator: ", ") + ".",
                                suggestion: "Delete it from Saved Filters, or add the columns back.")
        }
        draft = tree
        savedName = name
        focusedRuleID = nil
        if let rule = tree.firstUnsetRule ?? tree.rules.first?.id { focus = Focus(rule: rule) }
        return apply()
    }
}
