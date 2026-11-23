import AppKit
import Foundation
import QuarryKit
import QuarryControllers

/// Show Create Statement… (⌃⌘C) and Copy Create Statement (⇧⌘C) for the
/// sidebar's selection: tables, views and routines (S-028).
extension Session {
    /// Every selected object, any kind, in sidebar order; or the context menu's rows.
    func createStatementTargets(_ ids: Set<String>? = nil) -> [DBObject] {
        guard phase == .connected, database != nil else { return [] }
        let chosen = ids ?? (sidebarSelection.isEmpty ? Set([selectedObjectID].compactMap { $0 }) : sidebarSelection)
        return objects.filter { chosen.contains($0.id) }
    }

    /// The sheet's title: "Create Statement for Table “orders”", "Create Statements for 3 Items".
    static func createStatementTitle(_ objects: [DBObject]) -> String {
        guard objects.count == 1, let object = objects.first else { return "Create Statements for \(objects.count) Items" }
        return "Create Statement for \(CreateScript.noun(object.kind).capitalized) \u{201C}\(object.name)\u{201D}"
    }

    /// Opens the sheet, which fills in when the statements arrive.
    /// The returned task ends when they have (self-test).
    @discardableResult
    func requestShowCreateStatement(_ ids: Set<String>? = nil) -> Task<Void, Never>? {
        let targets = createStatementTargets(ids)
        guard !targets.isEmpty, let database, createStatementSheet == nil else { return nil }
        let sheet = CreateStatementSheetModel(database: database, objects: targets,
                                              title: Self.createStatementTitle(targets))
        createStatementSheet = sheet
        return Task {
            do {
                sheet.text = try await createScript(targets, in: database)
                sheet.isLoading = false
            } catch {
                if createStatementSheet === sheet { createStatementSheet = nil }
                alert = .failure("Couldn’t get the create statement", error)
            }
        }
    }

    /// Copies the statements without a sheet. The returned task ends when they are on the pasteboard.
    @discardableResult
    func copyCreateStatement(_ ids: Set<String>? = nil) -> Task<Void, Never>? {
        let targets = createStatementTargets(ids)
        guard !targets.isEmpty, let database else { return nil }
        return Task {
            do {
                Self.copyToPasteboard(try await createScript(targets, in: database))
            } catch {
                alert = .failure("Couldn’t copy the create statement", error)
            }
        }
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// One SHOW CREATE per object. The server gives NULL when the user may not see it.
    private func createScript(_ targets: [DBObject], in database: String) async throws -> String {
        guard let client else { throw DatabaseError(message: "Not connected.") }
        var items: [CreateScript.Item] = []
        for object in targets {
            let statement = try await client.createStatement(of: object, in: database)
            guard !statement.isEmpty else {
                throw DatabaseError(message: "The server didn’t give the create statement for \u{201C}\(object.name)\u{201D}. "
                    + "Ask an administrator for permission to see it.")
            }
            items.append(CreateScript.Item(object: object, statement: statement))
        }
        return CreateScript.text(items)
    }
}

/// The Show Create Statement sheet's state.
@MainActor @Observable
final class CreateStatementSheetModel: Identifiable {
    let database: String
    let objects: [DBObject]
    let title: String
    var text = ""
    var isLoading = true
    /// "Copied" shows until the text changes or the sheet closes.
    var copied = false
    var saveError: String?

    init(database: String, objects: [DBObject], title: String) {
        self.database = database
        self.objects = objects
        self.title = title
    }

    var fileName: String {
        CreateScript.fileName(objects.map { CreateScript.Item(object: $0, statement: "") }, database: database)
    }

    func copy() {
        Session.copyToPasteboard(text)
        copied = true
    }
}
