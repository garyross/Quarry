import Foundation

/// Content's filter (S-014, S-015): rules in groups, like Finder's search
/// criteria. A group matches when all, any, or none of its items match; a
/// group can hold groups.
///
/// The top group ("All of the following are true") always exists and starts
/// empty: no filter. + adds a rule below a line, ⇥ adds a group below it, −
/// removes a line (on the top group: every rule). A rule whose value is not
/// set yet is ignored, and so is a group with nothing set.
public struct FilterTree: Sendable, Hashable, Codable {
    public enum Match: String, CaseIterable, Sendable, Identifiable, Codable {
        case all = "All", any = "Any", none = "None"
        public var id: String { rawValue }
    }

    public struct Group: Sendable, Hashable, Identifiable, Codable {
        public var id = UUID()
        public var match: Match
        public var items: [Item]

        public init(match: Match, items: [Item]) {
            self.match = match
            self.items = items
        }
    }

    public enum Item: Sendable, Hashable, Identifiable, Codable {
        case rule(id: UUID, RowFilter)
        case group(Group)

        public var id: UUID {
            switch self {
            case .rule(let id, _): id
            case .group(let group): group.id
            }
        }

        /// The item and every item inside it.
        var allIDs: Set<UUID> {
            switch self {
            case .rule(let id, _): [id]
            case .group(let group): group.items.reduce(into: [group.id]) { $0.formUnion($1.allIDs) }
            }
        }
    }

    /// One line of the editor: a group's header or a rule, with its depth.
    public struct Row: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            case header(Match, isRoot: Bool)
            case rule(RowFilter)
        }
        public let id: UUID
        public let depth: Int
        public let kind: Kind

        public var isRule: Bool { if case .rule = kind { true } else { false } }
        public var isRoot: Bool { if case .header(_, true) = kind { true } else { false } }
    }

    public private(set) var root: Group

    /// No rules: "All of the following are true" and nothing under it.
    public init() {
        root = Group(match: .all, items: [])
    }

    /// One rule under the top group.
    public init(_ rule: RowFilter) {
        root = Group(match: .all, items: [.rule(id: UUID(), rule)])
    }

    public init(root: Group) {
        self.root = root
    }

    public var isEmpty: Bool { root.items.isEmpty }

    /// The editor's lines, top to bottom; the top group's header comes first.
    public var rows: [Row] {
        var rows: [Row] = []
        func walk(_ group: Group, depth: Int, isRoot: Bool) {
            rows.append(Row(id: group.id, depth: depth, kind: .header(group.match, isRoot: isRoot)))
            for item in group.items {
                switch item {
                case .rule(let id, let rule): rows.append(Row(id: id, depth: depth + 1, kind: .rule(rule)))
                case .group(let child): walk(child, depth: depth + 1, isRoot: false)
                }
            }
        }
        walk(root, depth: 0, isRoot: true)
        return rows
    }

    /// Every rule, top to bottom.
    public var rules: [(id: UUID, rule: RowFilter)] {
        rows.compactMap { row in
            if case .rule(let rule) = row.kind { return (row.id, rule) }
            return nil
        }
    }

    public func rule(_ id: UUID) -> RowFilter? { rules.first { $0.id == id }?.rule }

    /// The first rule still waiting for a value: where a saved filter puts the cursor.
    public var firstUnsetRule: UUID? { rules.first { !$0.rule.isSet && $0.rule.op.valueCount > 0 }?.id }

    /// Every column the rules name; a WHERE clause rule names none it can check.
    public var columns: Set<String> { Set(rules.filter { $0.rule.op != .sql }.map(\.rule.column)) }

    /// The text of every WHERE clause rule (S-061), top to bottom: typing in one
    /// waits for Return instead of filtering after a pause.
    public var typedClauses: [String] { rules.filter { $0.rule.op == .sql }.map(\.rule.value) }

    // MARK: Saving

    /// The tree as JSON, for a saved filter. Rules with no value are kept.
    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// A saved filter's tree, with new ids so two opens never share them.
    public static func decoded(_ data: Data) -> FilterTree? {
        guard let tree = try? JSONDecoder().decode(FilterTree.self, from: data) else { return nil }
        return FilterTree(root: tree.root.withNewIDs())
    }

    // MARK: Changing it

    public mutating func setRule(_ id: UUID, _ rule: RowFilter) {
        Self.edit(&root) { items, index in
            guard case .rule(let found, _) = items[index], found == id else { return false }
            items[index] = .rule(id: id, rule)
            return true
        }
    }

    public mutating func setMatch(_ groupID: UUID, _ match: Match) {
        if root.id == groupID { root.match = match; return }
        Self.edit(&root) { items, index in
            guard case .group(var group) = items[index], group.id == groupID else { return false }
            group.match = match
            items[index] = .group(group)
            return true
        }
    }

    /// + : `rule` on the line below `id`. Below a rule is the next item in its
    /// group; below a group's header is the group's first item.
    @discardableResult
    public mutating func add(_ rule: RowFilter, below id: UUID) -> UUID {
        let newID = UUID()
        insert(.rule(id: newID, rule), below: id)
        return newID
    }

    /// ⇥ : a new group below `id` holding `rule`. It starts as the opposite of
    /// the group it lands in (All under Any, Any otherwise), the usual reason
    /// to nest. Returns the new rule's id.
    @discardableResult
    public mutating func addGroup(_ rule: RowFilter, below id: UUID) -> UUID {
        let newID = UUID()
        let parent = parentMatch(below: id)
        let group = Group(match: parent == .any ? .all : .any, items: [.rule(id: newID, rule)])
        insert(.group(group), below: id)
        return newID
    }

    /// − : a rule or a group with its rules. A group left empty goes too.
    /// On the top group it removes every rule and keeps the header.
    public mutating func remove(_ id: UUID) {
        if id == root.id {
            root.items = []
            return
        }
        _ = Self.remove(id, from: &root)
    }

    /// Drag and drop: puts `id` on the line below `target` (as `add` would).
    /// A group can't go inside itself; the top group can't move.
    @discardableResult
    public mutating func move(_ id: UUID, below target: UUID) -> Bool {
        guard id != target, id != root.id, let item = item(id), !item.allIDs.contains(target) else { return false }
        var copy = self
        _ = Self.removeItem(id, from: &copy.root)
        guard copy.contains(target) else { return false }
        copy.insert(item, below: target)
        Self.prune(&copy.root)
        self = copy
        return true
    }

    public func contains(_ id: UUID) -> Bool { id == root.id || Item.group(root).allIDs.contains(id) }

    private func item(_ id: UUID) -> Item? {
        func find(_ group: Group) -> Item? {
            for item in group.items {
                if item.id == id { return item }
                if case .group(let child) = item, let found = find(child) { return found }
            }
            return nil
        }
        return find(root)
    }

    /// The match of the group an item inserted below `id` lands in.
    private func parentMatch(below id: UUID) -> Match {
        func find(_ group: Group) -> Match? {
            if group.id == id { return group.match }
            for item in group.items {
                if item.id == id, case .rule = item { return group.match }
                if case .group(let child) = item, let found = find(child) { return found }
            }
            return nil
        }
        return find(root) ?? root.match
    }

    private mutating func insert(_ new: Item, below id: UUID) {
        if root.id == id {
            root.items.insert(new, at: 0)
            return
        }
        let found = Self.edit(&root) { items, index in
            guard items[index].id == id else { return false }
            if case .group(var group) = items[index] {
                group.items.insert(new, at: 0)
                items[index] = .group(group)
            } else {
                items.insert(new, at: index + 1)
            }
            return true
        }
        if !found { root.items.append(new) }
    }

    /// Removes an item; a group it leaves empty goes too.
    private static func remove(_ id: UUID, from group: inout Group) -> Bool {
        if let index = group.items.firstIndex(where: { $0.id == id }) {
            group.items.remove(at: index)
            return true
        }
        for index in group.items.indices {
            guard case .group(var child) = group.items[index] else { continue }
            if remove(id, from: &child) {
                if child.items.isEmpty { group.items.remove(at: index) } else { group.items[index] = .group(child) }
                return true
            }
        }
        return false
    }

    /// Removes an item but keeps the group it leaves (a drag may land on its header).
    private static func removeItem(_ id: UUID, from group: inout Group) -> Bool {
        if let index = group.items.firstIndex(where: { $0.id == id }) {
            group.items.remove(at: index)
            return true
        }
        for index in group.items.indices {
            guard case .group(var child) = group.items[index] else { continue }
            if removeItem(id, from: &child) {
                group.items[index] = .group(child)
                return true
            }
        }
        return false
    }

    /// Drops groups a drag left empty.
    private static func prune(_ group: inout Group) {
        group.items = group.items.compactMap { item in
            guard case .group(var child) = item else { return item }
            prune(&child)
            return child.items.isEmpty ? nil : .group(child)
        }
    }

    /// Finds the first item for which `change` returns true, depth first.
    @discardableResult
    private static func edit(_ group: inout Group, _ change: (inout [Item], Int) -> Bool) -> Bool {
        for index in group.items.indices {
            if change(&group.items, index) { return true }
            if case .group(var child) = group.items[index] {
                if edit(&child, change) {
                    group.items[index] = .group(child)
                    return true
                }
            }
        }
        return false
    }

    // MARK: SQL

    /// The rules that take part: those with their values set.
    public var activeRules: [RowFilter] { rules.map(\.rule).filter(\.isSet) }

    /// The condition without `WHERE`, or nil when nothing is set.
    /// Groups inside groups are wrapped in parentheses; None is NOT (a OR b).
    public var whereClause: String? { whereClause(engine: .mysql) }

    /// The condition as `engine` quotes it (S-071: SQLite has no backslash escapes).
    public func whereClause(engine: Engine) -> String? { Self.clause(root, nested: false, engine: engine) }

    private static func clause(_ group: Group, nested: Bool, engine: Engine) -> String? {
        let parts: [String] = group.items.compactMap { item in
            switch item {
            case .rule(_, let rule): rule.whereClause(engine: engine)
            case .group(let child): clause(child, nested: true, engine: engine)
            }
        }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: group.match == .all ? " AND " : " OR ")
        switch group.match {
        case .none: return "NOT (" + joined + ")"
        default: return nested && parts.count > 1 ? "(" + joined + ")" : joined
        }
    }
}

extension FilterTree.Group {
    func withNewIDs() -> FilterTree.Group {
        var copy = FilterTree.Group(match: match, items: items.map { item in
            switch item {
            case .rule(_, let rule): .rule(id: UUID(), rule)
            case .group(let group): .group(group.withNewIDs())
            }
        })
        copy.id = UUID()
        return copy
    }
}

/// Picking a new rule's column, and how long to wait before searching.
public enum FilterDefaults {
    /// The auto-increment column, else the primary key, else a unique column,
    /// else an indexed one, else the first column.
    public static func column(_ fields: [FieldInfo]) -> String? {
        if let field = fields.first(where: { $0.extra.lowercased().contains("auto_increment") }) { return field.name }
        for key in ["PRI", "UNI", "MUL"] {
            if let field = fields.first(where: { $0.key == key }) { return field.name }
        }
        return fields.first?.name
    }

    /// Typing searches after a pause: 0.5 s when every rule can use an index,
    /// 1 s when one has to read the whole table.
    public static func delay(for rules: [RowFilter], indexed: Set<String>) -> Duration {
        rules.allSatisfy { $0.canUseIndex(indexed: indexed) } ? .milliseconds(500) : .milliseconds(1000)
    }
}
