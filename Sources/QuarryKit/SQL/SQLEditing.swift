import Foundation

/// One change to the editor's text: replace `range` with `replacement`, then
/// select `selection`. Ranges are UTF-16 (NSString / NSRange), like the editor.
public struct TextEdit: Sendable, Equatable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// The text after the edit.
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }

    /// The edit that puts `text` back as it was before this one (what Undo does).
    public func inverse(in text: String) -> TextEdit {
        let original = (text as NSString).substring(with: range)
        let changed = NSRange(location: range.location, length: (replacement as NSString).length)
        return TextEdit(range: changed, replacement: original, selection: range)
    }
}

/// The query editor's helpers (S-032): comment lines, shift indentation,
/// select the current statement, uppercase keywords as they are typed, and
/// matching brackets and quotes. Pure functions over the text and selection;
/// the editor applies the `TextEdit` so Undo restores it in one step.
public enum SQLEditing {
    /// What Shift Right adds at the start of each line.
    public static let indent = "\t"
    /// What Comment Line adds.
    public static let commentPrefix = "-- "

    // MARK: Lines

    /// The whole lines a selection touches, without the last line's newline.
    /// A selection that ends at the start of a line leaves that line out, as in Xcode.
    public static func lineBlock(_ text: String, selection: NSRange) -> NSRange {
        let ns = text as NSString
        let start = ns.lineRange(for: NSRange(location: min(selection.location, ns.length), length: 0)).location
        var endProbe = NSMaxRange(selection)
        if selection.length > 0, endProbe > start, endProbe <= ns.length, isNewline(ns.character(at: endProbe - 1)) {
            endProbe -= 1
        }
        var end = NSMaxRange(ns.lineRange(for: NSRange(location: min(endProbe, ns.length), length: 0)))
        if end > start, end <= ns.length, isNewline(ns.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The lines of `block`, each without its newline.
    private static func lines(_ text: String, in block: NSRange) -> [String] {
        (text as NSString).substring(with: block).components(separatedBy: "\n")
    }

    private static func isNewline(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }

    private static func leadingWhitespace(_ line: String) -> Substring {
        line.prefix { $0 == " " || $0 == "\t" }
    }

    /// The edit for a line-by-line change of `block`. A caret stays on its line,
    /// moved by what changed before it there; a selection covers the new lines.
    private static func lineEdit(_ text: String, selection: NSRange, block: NSRange,
                                 transform: (String) -> String) -> TextEdit? {
        let old = lines(text, in: block)
        let new = old.map(transform)
        guard new != old else { return nil }
        let replacement = new.joined(separator: "\n")
        let length = (replacement as NSString).length
        if selection.length == 0, old.count == 1 {
            // Keep the caret on the same character of its line.
            let column = selection.location - block.location
            let before = (old[0] as NSString).length
            let after = (new[0] as NSString).length
            let caret = block.location + max(0, min(after, column + (after - before)))
            return TextEdit(range: block, replacement: replacement, selection: NSRange(location: caret, length: 0))
        }
        return TextEdit(range: block, replacement: replacement,
                        selection: NSRange(location: block.location, length: length))
    }

    // MARK: Comment Line (⌘/) and Comment Current Statement (⌥⌘/)

    /// Whether a line is a line comment (`-- ` or `#`).
    public static func isCommentLine(_ line: String) -> Bool {
        let body = line.drop { $0 == " " || $0 == "\t" }
        return body.hasPrefix("--") || body.hasPrefix("#")
    }

    /// Comments the selected lines with `-- `, or uncomments them when every
    /// non-blank line is already a comment. The comment goes at the smallest
    /// indent, so the lines keep their shape.
    public static func toggleComment(_ text: String, selection: NSRange) -> TextEdit? {
        toggleComment(text, selection: selection, block: lineBlock(text, selection: selection))
    }

    /// Comment Current Statement: the lines of the statement at the caret. On a
    /// commented line it takes the run of commented lines around it, which is
    /// what an earlier Comment Current Statement made, and uncomments them.
    public static func toggleStatementComment(_ text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let caretLine = lineBlock(text, selection: NSRange(location: selection.location, length: 0))
        if isCommentLine(ns.substring(with: caretLine)) {
            var block = caretLine
            // Grow up and down while the neighbouring lines are comments.
            while block.location > 0 {
                let previous = lineBlock(text, selection: NSRange(location: block.location - 1, length: 0))
                guard isCommentLine(ns.substring(with: previous)) else { break }
                block = NSUnionRange(previous, block)
            }
            while NSMaxRange(block) < ns.length {
                let next = lineBlock(text, selection: NSRange(location: NSMaxRange(block) + 1, length: 0))
                guard next.length > 0, isCommentLine(ns.substring(with: next)) else { break }
                block = NSUnionRange(block, next)
            }
            return toggleComment(text, selection: selection, block: block)
        }
        guard let statement = currentStatement(text, at: selection.location) else { return nil }
        let block = lineBlock(text, selection: statement)
        return toggleComment(text, selection: NSRange(location: block.location, length: block.length), block: block)
    }

    private static func toggleComment(_ text: String, selection: NSRange, block: NSRange) -> TextEdit? {
        let old = lines(text, in: block)
        let filled = old.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !filled.isEmpty else { return nil }
        if filled.allSatisfy(isCommentLine) {
            return lineEdit(text, selection: selection, block: block) { line in
                let indent = leadingWhitespace(line)
                var body = line.dropFirst(indent.count)
                if body.hasPrefix("-- ") { body = body.dropFirst(3) }
                else if body.hasPrefix("--") { body = body.dropFirst(2) }
                else if body.hasPrefix("# ") { body = body.dropFirst(2) }
                else if body.hasPrefix("#") { body = body.dropFirst(1) }
                return String(indent) + body
            }
        }
        let column = filled.map { leadingWhitespace($0).count }.min() ?? 0
        return lineEdit(text, selection: selection, block: block) { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            return String(line.prefix(column)) + commentPrefix + line.dropFirst(column)
        }
    }

    // MARK: Shift Right (⌘]) and Shift Left (⌘[)

    /// Adds a tab before each selected line (blank lines in a selection stay empty).
    public static func shiftRight(_ text: String, selection: NSRange) -> TextEdit? {
        let block = lineBlock(text, selection: selection)
        let single = lines(text, in: block).count == 1
        return lineEdit(text, selection: selection, block: block) { line in
            line.isEmpty && !single ? line : indent + line
        }
    }

    /// Removes one tab, or up to four spaces, from the start of each selected line.
    public static func shiftLeft(_ text: String, selection: NSRange) -> TextEdit? {
        let block = lineBlock(text, selection: selection)
        return lineEdit(text, selection: selection, block: block) { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix(4).prefix { $0 == " " }.count
            return String(line.dropFirst(spaces))
        }
    }

    // MARK: Select Current Statement (⌃Y)

    /// The statement at the caret, as Run Current Statement would run it.
    public static func currentStatement(_ text: String, at location: Int) -> NSRange? {
        StatementSplitter.statement(at: location, in: StatementSplitter.split(text))?.range
    }

    // MARK: Uppercase keywords

    /// Keywords that often name columns (`status`, `date`, `comment`), so typing
    /// them never changes their case.
    public static let keepCase: Set<String> = [
        "DATE", "DATETIME", "TIME", "TIMESTAMP", "TEXT", "STATUS", "COMMENT", "JSON", "ENGINE", "ROW",
        "START", "END", "BEGIN", "OFFSET", "FULL", "EACH", "DO", "ENUM", "TEMPORARY", "VIEW", "KEY",
        "BINARY", "CHAR", "COLUMN", "INDEX", "SCHEMA", "TRANSACTION", "FUNCTION", "TRIGGER", "PROCEDURE",
        "DATABASE", "TABLE", "USE",
    ]
    /// Functions: uppercased only when "(" follows, since `count` and `max` are also column names.
    public static let functions: Set<String> = ["COUNT", "SUM", "AVG", "MIN", "MAX", "CONCAT", "COALESCE", "IFNULL", "NOW"]

    /// When a character that ends a word is typed at `location`, the keyword just
    /// before it in uppercase, or nil. Nothing changes inside strings, comments or
    /// backticks, after a dot (`orders.status`), or for words in `keepCase`.
    public static func uppercaseKeyword(_ text: String, before location: Int, typed: String) -> TextEdit? {
        guard let typedUnit = typed.utf16.first, typed.utf16.count == 1, !isWordUnit(typedUnit), typedUnit != 46 else { return nil }
        let ns = text as NSString
        guard location > 0, location <= ns.length, isWordUnit(ns.character(at: location - 1)) else { return nil }
        var start = location
        while start > 0, isWordUnit(ns.character(at: start - 1)) { start -= 1 }
        if start > 0 {
            let before = ns.character(at: start - 1)
            if before == 46 || before == 64 || before == 96 { return nil } // . @ `
        }
        let range = NSRange(location: start, length: location - start)
        let word = ns.substring(with: range)
        let upper = word.uppercased()
        guard word != upper, SQLHighlighter.keywords.contains(upper), !keepCase.contains(upper) else { return nil }
        if functions.contains(upper), typed != "(" { return nil }
        // The word must be a keyword token, not part of a string or comment.
        let prefix = ns.substring(to: location)
        guard SQLHighlighter.tokens(in: prefix).last.map({ $0.kind == .keyword && $0.range == range }) == true else { return nil }
        return TextEdit(range: range, replacement: upper, selection: NSRange(location: location, length: 0))
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit == 36 || unit > 127
    }

    // MARK: Matching brackets and quotes

    public enum PairAction: Sendable, Equatable {
        /// Insert the opener and its match, the caret between them; the match is linked.
        case insertPair(TextEdit, linked: NSRange)
        /// Put the opener and its match around the selection, which stays selected.
        case wrap(TextEdit)
        /// The typed closer is already there (a linked one): step over it.
        case skip(NSRange)
    }

    /// The closer for each opener.
    public static let pairs: [String: String] = ["(": ")", "'": "'", "\"": "\"", "`": "`"]

    /// What typing `typed` does with matching characters on, or nil to type it
    /// normally. `nextIsLinked` says the character after the caret was inserted
    /// as a match and not typed.
    public static func pair(_ text: String, selection: NSRange, typed: String, nextIsLinked: Bool) -> PairAction? {
        guard typed.utf16.count == 1 else { return nil }
        let ns = text as NSString
        let caret = selection.location
        let next: unichar? = caret < ns.length ? ns.character(at: caret) : nil
        let previous: unichar? = caret > 0 ? ns.character(at: caret - 1) : nil
        let unit = typed.utf16.first!

        // Typing the closer that was inserted for you steps over it.
        if selection.length == 0, nextIsLinked, next == unit, typed == ")" || pairs[typed] == typed {
            return .skip(NSRange(location: caret + 1, length: 0))
        }
        guard let closer = pairs[typed] else { return nil }

        if selection.length > 0 {
            let inner = ns.substring(with: selection)
            guard !inner.contains("\n") || typed == "(" else { return nil }
            let edit = TextEdit(range: selection, replacement: typed + inner + closer,
                                selection: NSRange(location: selection.location + 1, length: selection.length))
            return .wrap(edit)
        }
        if insideStringOrComment(ns.substring(to: caret)) { return nil }
        // Before a word: "(" or a quote would only wrap it by accident.
        if let next, isWordUnit(next) { return nil }
        // After a word, a quote is an apostrophe or closes something; "(" still pairs (COUNT().
        if typed != "(", let previous, isWordUnit(previous) || previous == 92 { return nil }
        let edit = TextEdit(range: NSRange(location: caret, length: 0), replacement: typed + closer,
                            selection: NSRange(location: caret + 1, length: 0))
        return .insertPair(edit, linked: NSRange(location: caret + 1, length: 1))
    }

    /// Delete between an empty linked pair, `(|)` or `'|'`, removes both.
    public static func deletesPair(_ text: String, caret: Int, nextIsLinked: Bool) -> NSRange? {
        let ns = text as NSString
        guard nextIsLinked, caret > 0, caret < ns.length else { return nil }
        let opener = ns.substring(with: NSRange(location: caret - 1, length: 1))
        let closer = ns.substring(with: NSRange(location: caret, length: 1))
        guard pairs[opener] == closer else { return nil }
        return NSRange(location: caret - 1, length: 2)
    }

    /// Whether the end of `prefix` is inside an open string, backtick name or comment.
    static func insideStringOrComment(_ prefix: String) -> Bool {
        let units = Array(prefix.utf16)
        guard let last = SQLHighlighter.tokens(in: prefix).last, NSMaxRange(last.range) == units.count else { return false }
        let token = Array(units[last.range.location..<NSMaxRange(last.range)])
        switch last.kind {
        case .comment:
            if token.starts(with: [47, 42]) { return !(token.count >= 4 && token.suffix(2) == [42, 47]) }
            return true // a line comment runs to the end of the line
        case .string, .identifier:
            guard let quote = token.first, quote == 39 || quote == 34 || quote == 96 else { return false }
            if token.count < 2 || token.last != quote { return true }
            // Count the quotes and escapes to see whether the last one closes it.
            var k = 1
            while k < token.count {
                if token[k] == 92, quote != 96 { k += 2; continue }
                if token[k] == quote {
                    if k + 1 < token.count, token[k + 1] == quote { k += 2; continue }
                    return k != token.count - 1
                }
                k += 1
            }
            return true
        default:
            return false
        }
    }

    // MARK: Indent new lines

    /// The spaces and tabs that start the line holding `location`, for Return to copy.
    public static func indentation(_ text: String, at location: Int) -> String {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        let head = ns.substring(with: NSRange(location: line.location, length: max(0, min(location, ns.length) - line.location)))
        return String(leadingWhitespace(head))
    }
}
