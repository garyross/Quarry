import AppKit
import Foundation
import Observation
import QuarryKit

/// The Server Variables sheet (S-052): SHOW VARIABLES, filtered as people type.
@Observable
final class VariableList: Identifiable {
    let id = UUID()
    /// The connection's name, for the saved file's first line.
    let server: String

    private(set) var variables: [ServerVariable] = []
    private(set) var isLoading = true
    private(set) var error: DatabaseError?
    var search = ""
    var selection: Set<ServerVariable.ID> = []

    init(server: String) {
        self.server = server
    }

    func load(_ client: DatabaseClient) async {
        isLoading = true
        defer { isLoading = false }
        do {
            variables = try await client.serverVariables()
            error = nil
        } catch {
            self.error = DatabaseError.from(error)
        }
    }

    var isFiltering: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var shown: [ServerVariable] { ServerVariable.filter(variables, search) }

    var countText: String {
        ServerVariable.countText(shown: shown.count, total: variables.count, filtering: isFiltering)
    }

    /// Save As… saves every variable; while filtering, Save View As… saves the ones shown.
    var saveTitle: String { isFiltering ? "Save View As…" : "Save As…" }

    /// The selected variables in list order; `ids` from a context menu, else the selection.
    func selected(_ ids: Set<ServerVariable.ID>? = nil) -> [ServerVariable] {
        let ids = ids ?? selection
        return shown.filter { ids.contains($0.id) }
    }

    /// Copy, Copy Variable Name(s), Copy Variable Value(s). False when nothing is selected.
    @discardableResult
    func copy(_ part: ServerVariable.Part, _ ids: Set<ServerVariable.ID>? = nil) -> Bool {
        let variables = selected(ids)
        guard !variables.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ServerVariable.copyText(variables, part), forType: .string)
        return true
    }

    func save(to url: URL) throws {
        try ServerVariable.cnfText(shown, server: server).write(to: url, atomically: true, encoding: .utf8)
    }
}
