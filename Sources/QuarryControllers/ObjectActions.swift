import Foundation
import QuarryKit

/// What the sidebar's objects can do right now (S-021, S-022, S-030): one rule
/// per command, read by the Table menu, the sidebar's row menu and + buttons, ⌫,
/// Info's Definition row and each action's own guard, so they can't disagree
/// (FIXLOG: a read-only file offered Delete Table).
///
/// Most commands work on the clicked rows, else the sidebar's selection, else
/// the shown object. Edit View/Procedure/Function works on the clicked or
/// selected object only.
package struct ObjectActions {
    /// The objects most commands work on, in sidebar order.
    package let targets: [DBObject]
    /// The one view or routine Edit works on, if any.
    package let definition: DBObject?
    private let canWrite: Bool
    private let canCreateIn: Bool
    private let engine: Engine

    /// - Parameters:
    ///   - objects: the sidebar's objects, in its order.
    ///   - clicked: the context menu's rows, or nil for the menu bar and keys.
    ///   - selection: the sidebar's selection.
    ///   - shown: the object the detail shows.
    package init(isConnected: Bool, database: String?, isReadOnly: Bool, engine: Engine, objects: [DBObject],
                 clicked: Set<String>? = nil, selection: Set<String> = [], shown: String? = nil) {
        let open = isConnected && database != nil
        let chosen = clicked ?? (selection.isEmpty ? Set([shown].compactMap { $0 }) : selection)
        targets = open ? objects.filter { chosen.contains($0.id) } : []
        let picked = clicked ?? selection
        let one = picked.count == 1 ? objects.first { $0.id == picked.first } : nil
        definition = open && !isReadOnly ? one.flatMap { $0.kind == .table ? nil : $0 } : nil
        canWrite = !isReadOnly
        canCreateIn = open && !isReadOnly
        self.engine = engine
    }

    /// Rename (⌃⌘R): one table or view.
    package var rename: DBObject? {
        canWrite && targets.count == 1 && targets[0].kind.hasRows ? targets[0] : nil
    }

    /// Duplicate Table… (⌃⌘D): one table.
    package var duplicate: DBObject? { rename.flatMap { $0.kind == .table ? $0 : nil } }

    /// Empty (⌃⌘⌫): only when every target is a table.
    package var empty: [DBObject] { canWrite && targets.allSatisfy { $0.kind == .table } ? targets : [] }

    /// Delete (⌥⌘⌫ or ⌫): tables, views and routines.
    package var delete: [DBObject] { canWrite ? targets : [] }

    /// New Table…, New View…, New Procedure…, New Function…: a SQLite file has no routines.
    package func canCreate(_ kind: ObjectKind) -> Bool {
        canCreateIn && (engine == .mysql || kind == .table || kind == .view)
    }

    package var renameTitle: String { Self.title("Rename", rename.map { [$0] } ?? []) }
    package var emptyTitle: String { Self.title("Empty", empty) }
    package var deleteTitle: String { Self.title("Delete", targets) }
    package var editDefinitionTitle: String { Self.editDefinitionTitle(definition) }

    /// "Rename Table…", "Delete View…", "Delete Procedure…", "Delete 3 Items…".
    package static func title(_ verb: String, _ objects: [DBObject]) -> String {
        let kinds = Set(objects.map(\.kind))
        let noun = kinds.count > 1 ? "Item" : CreateScript.noun(kinds.first ?? .table).capitalized
        return objects.count > 1 ? "\(verb) \(objects.count) \(noun)s…" : "\(verb) \(noun)…"
    }

    /// "Edit View…", "Edit Procedure…", "Edit Function…".
    package static func editDefinitionTitle(_ object: DBObject?) -> String {
        guard let object, object.kind != .table else { return "Edit View…" }
        return "Edit \(CreateScript.noun(object.kind).capitalized)…"
    }
}
