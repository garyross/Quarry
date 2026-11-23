import AppKit
import QuarryKit
import SwiftUI

/// Read-only SQL in a SwiftUI `Text`, colored like the SQL editor.
enum SQLText {
    static func highlighted(_ sql: String) -> AttributedString {
        let string = NSMutableAttributedString(string: sql, attributes: [.foregroundColor: DataStyle.Syntax.plain])
        for token in SQLHighlighter.tokens(in: sql) {
            string.addAttribute(.foregroundColor, value: color(token.kind), range: token.range)
        }
        return (try? AttributedString(string, including: \.appKit)) ?? AttributedString(sql)
    }

    static func color(_ kind: SQLHighlighter.Kind) -> NSColor {
        switch kind {
        case .keyword: DataStyle.Syntax.keyword
        case .string: DataStyle.Syntax.string
        case .number: DataStyle.Syntax.number
        case .comment: DataStyle.Syntax.comment
        case .identifier: DataStyle.Syntax.identifier
        case .variable: DataStyle.Syntax.variable
        }
    }
}
