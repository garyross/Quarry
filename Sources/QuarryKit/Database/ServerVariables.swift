import Foundation

/// One row of SHOW VARIABLES (S-052).
public struct ServerVariable: Sendable, Hashable, Identifiable {
    public var name: String
    public var value: String
    public var id: String { name }

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    /// The variables whose name or value contains `text`, ignoring case; all of them for empty text.
    public static func filter(_ variables: [ServerVariable], _ text: String) -> [ServerVariable] {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return variables }
        return variables.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.value.localizedCaseInsensitiveContains(text) }
    }

    /// What Copy puts on the clipboard: "name = value" lines, or only names or values.
    public enum Part: Sendable { case both, name, value }

    public static func copyText(_ variables: [ServerVariable], _ part: Part) -> String {
        variables.map { variable in
            switch part {
            case .both: "\(variable.name) = \(variable.value)"
            case .name: variable.name
            case .value: variable.value
            }
        }.joined(separator: "\n")
    }

    /// Save As…'s file, in my.cnf's "name = value" form, as Sequel Pro wrote it.
    public static func cnfText(_ variables: [ServerVariable], server: String) -> String {
        "# Server variables for \(server)\n\n" + variables.map { "\($0.name) = \($0.value)\n" }.joined()
    }

    /// "12 of 640" while filtering, "640 variables" otherwise.
    public static func countText(shown: Int, total: Int, filtering: Bool) -> String {
        filtering ? "\(shown.formatted()) of \(total.formatted())" : (total == 1 ? "1 variable" : "\(total.formatted()) variables")
    }
}

extension DatabaseClient {
    /// SHOW VARIABLES: the session's view of every server variable, by name.
    public func serverVariables() async throws -> [ServerVariable] {
        let result = try await run("SHOW VARIABLES")
        return result.rows.indices.compactMap { row in
            guard let name = result.string(row, "Variable_name") else { return nil }
            return ServerVariable(name: name, value: result.string(row, "Value") ?? "")
        }
    }
}
