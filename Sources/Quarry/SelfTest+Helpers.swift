import AppKit
import QuarryKit
import QuarryControllers

/// Small lookups the self-test's areas share.
extension SelfTest {
    /// The first value a statement returns on the session's connection, as text.
    static func firstValue(in session: Session, _ sql: String) async -> String? {
        try? await session.client?.run(sql).rows.first?.first?.plainText
    }

    /// A grid column's index by title; 0 when there is none.
    static func column(in grid: GridData, _ name: String) -> Int {
        grid.columns.firstIndex { $0.title == name } ?? 0
    }
}
