import Foundation

/// One statement inside the Query editor's text.
public struct SQLStatement: Sendable, Equatable {
    /// The statement without its delimiter, trimmed.
    public var text: String
    /// Where `text` sits in the editor, in UTF-16 units (NSString / NSRange).
    public var range: NSRange
    /// From the end of the previous delimiter to the end of this one: a
    /// cursor anywhere in here belongs to this statement.
    public var span: NSRange
    /// 1-based line of the statement's first character.
    public var line: Int
}

/// Splits SQL into statements the way the mysql client does: `;` ends a
/// statement except inside quotes, backticks and comments, and a
/// `DELIMITER x` line changes the delimiter (for triggers and procedures).
public enum StatementSplitter {
    public static func split(_ sql: String) -> [SQLStatement] {
        let units = Array(sql.utf16)
        let count = units.count
        var statements: [SQLStatement] = []
        var delimiter: [UInt16] = Array(";".utf16)
        var start = 0          // start of the current statement's span
        var index = 0
        var lineStarts = [0]   // UTF-16 offsets where each line begins
        for (offset, unit) in units.enumerated() where unit == 10 { lineStarts.append(offset + 1) }

        func line(of offset: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low + 1
        }

        func emit(spanStart: Int, contentEnd: Int, spanEnd: Int) {
            var first = spanStart
            var last = contentEnd
            while first < last, isSpace(units[first]) { first += 1 }
            while last > first, isSpace(units[last - 1]) { last -= 1 }
            guard last > first else { return }
            let text = String(utf16CodeUnits: Array(units[first..<last]), count: last - first)
            statements.append(SQLStatement(
                text: text,
                range: NSRange(location: first, length: last - first),
                span: NSRange(location: spanStart, length: spanEnd - spanStart),
                line: line(of: first)))
        }

        func matches(_ pattern: [UInt16], at offset: Int) -> Bool {
            guard offset + pattern.count <= count else { return false }
            for k in 0..<pattern.count where units[offset + k] != pattern[k] { return false }
            return true
        }

        while index < count {
            let unit = units[index]
            // DELIMITER at the start of a line (only whitespace before it on the line).
            if isLineStart(units, index), let (newDelimiter, lineEnd) = delimiterCommand(units, at: index) {
                emit(spanStart: start, contentEnd: index, spanEnd: index)
                delimiter = newDelimiter
                index = lineEnd
                start = index
                continue
            }
            switch unit {
            case 39, 34, 96: // ' " `
                index = skipQuoted(units, from: index, quote: unit)
                continue
            case 35: // # comment
                index = skipToLineEnd(units, from: index)
                continue
            case 45 where index + 1 < count && units[index + 1] == 45
                && (index + 2 >= count || isSpace(units[index + 2])): // "-- "
                index = skipToLineEnd(units, from: index)
                continue
            case 47 where index + 1 < count && units[index + 1] == 42: // /* */
                index += 2
                while index < count, !(units[index] == 42 && index + 1 < count && units[index + 1] == 47) { index += 1 }
                index = min(count, index + 2)
                continue
            default:
                break
            }
            if matches(delimiter, at: index) {
                let end = index + delimiter.count
                emit(spanStart: start, contentEnd: index, spanEnd: end)
                index = end
                start = end
                continue
            }
            index += 1
        }
        emit(spanStart: start, contentEnd: count, spanEnd: count)
        return statements
    }

    /// The statement ⌘R runs: the one whose span holds the cursor. A cursor in
    /// the blank space after the last statement picks the last one.
    public static func statement(at cursor: Int, in statements: [SQLStatement]) -> SQLStatement? {
        if let hit = statements.first(where: { cursor >= $0.span.location && cursor < NSMaxRange($0.span) }) {
            return hit
        }
        // A cursor right after a delimiter, or past the end, belongs to the statement before it.
        return statements.last(where: { NSMaxRange($0.span) <= cursor }) ?? statements.first
    }

    // MARK: Scanning

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 32 || unit == 9 || unit == 10 || unit == 13
    }

    private static func isLineStart(_ units: [UInt16], _ index: Int) -> Bool {
        var k = index - 1
        while k >= 0 {
            if units[k] == 10 { return true }
            if units[k] != 32 && units[k] != 9 { return false }
            k -= 1
        }
        return true
    }

    /// "DELIMITER //" -> ("//", offset after the line).
    private static func delimiterCommand(_ units: [UInt16], at index: Int) -> ([UInt16], Int)? {
        let keyword = Array("DELIMITER".utf16)
        var k = index
        // Skip leading spaces on the line.
        while k < units.count, units[k] == 32 || units[k] == 9 { k += 1 }
        guard k + keyword.count < units.count else { return nil }
        for (offset, letter) in keyword.enumerated() {
            let unit = units[k + offset]
            let upper = (unit >= 97 && unit <= 122) ? unit - 32 : unit
            if upper != letter { return nil }
        }
        k += keyword.count
        guard units[k] == 32 || units[k] == 9 else { return nil }
        while k < units.count, units[k] == 32 || units[k] == 9 { k += 1 }
        let begin = k
        while k < units.count, !isSpace(units[k]) { k += 1 }
        guard k > begin else { return nil }
        let newDelimiter = Array(units[begin..<k])
        while k < units.count, units[k] != 10 { k += 1 }
        return (newDelimiter, min(units.count, k + 1))
    }

    private static func skipQuoted(_ units: [UInt16], from index: Int, quote: UInt16) -> Int {
        var k = index + 1
        while k < units.count {
            let unit = units[k]
            if unit == 92 && quote != 96 { k += 2; continue }      // backslash escape (not in backticks)
            if unit == quote {
                if k + 1 < units.count, units[k + 1] == quote { k += 2; continue } // doubled quote
                return k + 1
            }
            k += 1
        }
        return units.count
    }

    private static func skipToLineEnd(_ units: [UInt16], from index: Int) -> Int {
        var k = index
        while k < units.count, units[k] != 10 { k += 1 }
        return k
    }
}
