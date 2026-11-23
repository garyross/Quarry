import Foundation

/// When a SQL import into a SQLite file (S-071) opens and commits its own
/// transactions: statements go in batches of `size`, one transaction each,
/// which is many times faster than SQLite's one per statement. Statements
/// that can't run in a transaction (PRAGMA, VACUUM, ATTACH, DETACH) run
/// between batches, and a file's own BEGIN … COMMIT is left to the file.
public struct SQLiteImportBatch: Sendable {
    public static let defaultSize = 500

    public let size: Int
    /// Quarry's BEGIN is open.
    public private(set) var isOpen = false
    /// The file opened a transaction of its own.
    private var fileTransaction = false
    private var count = 0

    public init(size: Int = defaultSize) {
        self.size = max(1, size)
    }

    enum Kind: Equatable { case statement, transaction(opens: Bool), outside }

    /// What a statement does to the batch, by its first word.
    static func kind(of sql: String) -> Kind {
        let words = sql.split(whereSeparator: { $0.isWhitespace || $0 == ";" }).prefix(2).map { $0.uppercased() }
        switch words.first {
        case "BEGIN": return .transaction(opens: true)
        case "COMMIT", "END": return .transaction(opens: false)
        case "ROLLBACK": return words.count > 1 && words[1] == "TO" ? .statement : .transaction(opens: false)
        case "PRAGMA", "VACUUM", "ATTACH", "DETACH": return .outside
        default: return .statement
        }
    }

    /// The statements to run before `sql`: COMMIT to end a batch, BEGIN to start one.
    public mutating func before(_ sql: String) -> [String] {
        var out: [String] = []
        switch Self.kind(of: sql) {
        case .transaction(let opens):
            out += close().map { [$0] } ?? []
            fileTransaction = opens
        case .outside:
            out += close().map { [$0] } ?? []
        case .statement:
            if !isOpen, !fileTransaction {
                out.append("BEGIN")
                isOpen = true
                count = 0
            }
        }
        return out
    }

    /// COMMIT when the batch is full, after a statement ran.
    public mutating func after() -> String? {
        guard isOpen else { return nil }
        count += 1
        return count >= size ? close() : nil
    }

    /// COMMIT for an open batch, or nil.
    public mutating func close() -> String? {
        guard isOpen else { return nil }
        isOpen = false
        count = 0
        return "COMMIT"
    }
}
