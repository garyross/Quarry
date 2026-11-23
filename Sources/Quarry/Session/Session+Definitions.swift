import Foundation
import QuarryKit
import QuarryControllers

/// New View…, New Procedure…, New Function… and Edit View/Procedure/Function… (S-030).
extension Session {
    /// Table > New View… (and the + menu's items): opens an empty sheet.
    func requestNewDefinition(_ kind: ObjectKind) {
        guard kind != .table, objectActions().canCreate(kind), let database, definitionDraft == nil else { return }
        definitionDraft = DefinitionDraft(database: database, kind: kind, existing: objects, engine: engine)
    }

    /// Opens the sheet and reads the definition.
    func requestEditDefinition(_ ids: Set<String>? = nil) {
        guard let object = objectActions(ids).definition, let client, let database, definitionDraft == nil else { return }
        let draft = DefinitionDraft(database: database, kind: object.kind, editing: object.name, existing: objects,
                                    engine: engine)
        definitionDraft = draft
        currentLoad = Task { await draft.load(client) }
    }

    /// Create or Save in the sheet. On success the sheet closes, the sidebar
    /// reloads, and the object is selected: a new view on Content, a routine
    /// on Info. On an error the sheet stays filled in with the server's message.
    /// The returned task ends when the view has loaded (self-test).
    @discardableResult
    func saveDefinition() -> Task<Void, Never>? {
        guard let client, let draft = definitionDraft, draft.canSave else { return nil }
        return Task {
            let saved = await draft.save(client)
            guard database == draft.database else { return }
            do {
                try await loadObjects(client, draft.database)
            } catch {
                browseError = DatabaseError.from(error)
            }
            guard saved else { return }
            if definitionDraft === draft { definitionDraft = nil }
            let id = DBObject(name: draft.name, kind: draft.kind).id
            guard objects.contains(where: { $0.id == id }) else { return }
            if !(objects.first { $0.id == id }?.matches(objectFilter) ?? true) { objectFilter = "" }
            isNavigating = true
            selectedObjectID = id
            if !draft.isEdit { view = draft.kind == .view ? .content : .info }
            if !view.applies(to: draft.kind) { view = .info }
            isNavigating = false
            reloadCurrentView(force: true)
            await currentLoad?.value
        }
    }
}
