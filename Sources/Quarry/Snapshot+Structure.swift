import AppKit
import QuarryKit
import SwiftUI

/// Snapshot pages for Structure, indexes, Foreign Keys, Triggers and Info.
extension SnapshotPage {
    /// nil: not one of these pages. true: ready now. false: ready once the session's load ends.
    @MainActor
    func prepareStructure(_ session: Session, model: AppModel, local: SavedConnection?) async -> Bool? {
        switch self {
        case .structure: show(.structure, "table:orders", in: session)
        case .structureEditing, .fieldSheet:
            // S-023: customers' email in the Edit Field sheet; the first with its type menu open.
            show(.structure, "table:customers", in: session)
            await session.currentLoad?.value
            session.structure.selection = [2]
            session.requestEditField(row: 2)
            for _ in 0..<50 where session.structure.fieldSheet?.catalog == nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
        case .newIndex:
            // S-024: customers' name and email, a prefix on name, Advanced open.
            show(.structure, "table:customers", in: session)
            await session.currentLoad?.value
            let fields = session.structure.names
            session.structure.selection = IndexSet(["name", "email"].compactMap { fields.firstIndex(of: $0) })
            session.requestAddIndex()
            session.structure.indexSheet?.name = "idx_name_email"
            session.structure.indexSheet?.parts[0].prefix = "20"
            session.structure.indexSheet?.showsAdvanced = true
            session.structure.indexSheet?.storage = .btree
        case .newForeignKey:
            // S-025: orders' customer_id to customers.id, Cascade on update.
            show(.foreignKeys, "table:orders", in: session)
            await session.currentLoad?.value
            session.requestAddForeignKey()
            await session.currentLoad?.value
            guard let draft = session.foreignKeys.sheet else { return true }
            draft.name = "fk_orders_buyer"
            draft.field = "customer_id"
            draft.referencedTable = "customers"
            session.foreignKeyTableChanged()
            await session.currentLoad?.value
            draft.onUpdate = .cascade
        case .newTrigger:
            // S-026: a new trigger on orders with a two-line body.
            show(.triggers, "table:orders", in: session)
            await session.currentLoad?.value
            session.requestAddTrigger()
            await session.currentLoad?.value
            session.triggers.sheet?.statement = "BEGIN\n  IF NEW.total < 0 THEN SET NEW.total = 0; END IF;\nEND"
        case .foreignKeys: show(.foreignKeys, "table:order_items", in: session)
        case .triggers: show(.triggers, "table:orders", in: session)
        case .info: show(.info, "table:orders", in: session)
        default:
            return nil
        }
        return false
    }
}
