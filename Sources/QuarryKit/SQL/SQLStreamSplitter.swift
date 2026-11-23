import Foundation
import SQLite3

/// Splits a SQL file into statements as its bytes arrive, a buffer at a time
/// (S-044's import). The rules are `StatementSplitter`'s, the mysql client's:
/// `;` ends a statement except inside quotes, backticks and comments, and a
/// `DELIMITER x` line changes the delimiter for triggers and routines. A
/// quote, comment, delimiter or UTF-8 character split across two buffers is
/// waited for, never cut. It works on bytes, so the file's encoding is decoded
/// per statement by the caller. Statements that are only comments are dropped;
/// `/*! … */` comments are code, and kept.
///
/// For a SQLite file (S-071) the rules are `sqlite3`'s: no backslash escapes,
/// no `#` comments, `[name]` quotes a name, the `;`s inside a CREATE TRIGGER's
/// BEGIN … END don't end it, and a DELIMITER line stops the split:
/// `refusedDelimiterLine` says where.
public struct SQLStreamSplitter: Sendable {
    private enum State: Sendable { case normal, quote(UInt8), lineComment, blockComment }

    private var buffer: [UInt8] = []
    /// The next byte to look at.
    private var scan = 0
    /// Where the statement being read starts.
    private var start = 0
    private var delimiter: [UInt8] = [59]
    private var state = State.normal
    /// Only spaces and tabs since the last line break: a DELIMITER command may start here.
    private var atLineStart = true
    /// The statement has something the server would run, not just comments.
    private var hasCode = false
    /// Where its code begins, after any leading comments.
    private var codeStart = 0
    private let isSQLite: Bool
    /// Line breaks in the bytes already dropped from `buffer`.
    private var droppedLines = 0
    /// SQLite: the 1-based line of a DELIMITER command; nothing after it is split.
    public private(set) var refusedDelimiterLine: Int?

    public init(engine: Engine) {
        isSQLite = engine == .sqlite
    }

    /// Adds `bytes` and returns the statements they complete, trimmed, without their delimiter.
    public mutating func append(_ bytes: some Sequence<UInt8>) -> [[UInt8]] {
        buffer.append(contentsOf: bytes)
        return split(final: false)
    }

    /// The end of the file: whatever is left is the last statement.
    public mutating func finish() -> [[UInt8]] {
        split(final: true)
    }

    /// The delimiter in effect now, such as ";" or "//".
    public var currentDelimiter: String { String(decoding: delimiter, as: UTF8.self) }

    private mutating func split(final: Bool) -> [[UInt8]] {
        guard refusedDelimiterLine == nil else { return [] }
        var out: [[UInt8]] = []
        let count = buffer.count

        func markCode() {
            if !hasCode { codeStart = scan }
            hasCode = true
        }

        func emit(upTo end: Int) {
            if hasCode, let statement = trimmed(codeStart, end) { out.append(statement) }
            hasCode = false
        }

        scanning: while scan < count {
            let byte = buffer[scan]
            switch state {
            case .quote(91):                                         // SQLite's [name] ends at ]
                if byte == 93 { state = .normal }
                scan += 1
            case .quote(let quote):
                if byte == 92 && quote != 96 && !isSQLite {          // backslash escape, not in backticks
                    if scan + 1 >= count && !final { break scanning }
                    scan += 2
                } else if byte == quote {
                    if scan + 1 >= count && !final { break scanning } // a doubled quote may follow
                    if scan + 1 < count, buffer[scan + 1] == quote {
                        scan += 2
                    } else {
                        state = .normal
                        scan += 1
                    }
                } else {
                    scan += 1
                }
            case .lineComment:
                if byte == 10 {
                    state = .normal
                    atLineStart = true
                }
                scan += 1
            case .blockComment:
                if byte == 42 {
                    if scan + 1 >= count && !final { break scanning }
                    if scan + 1 < count, buffer[scan + 1] == 47 {
                        state = .normal
                        scan += 2
                        continue
                    }
                }
                scan += 1
            case .normal:
                if byte == 10 {
                    atLineStart = true
                    scan += 1
                    continue
                }
                if byte == 32 || byte == 9 || byte == 13 {
                    scan += 1
                    continue
                }
                if atLineStart, byte == 68 || byte == 100 {          // D or d
                    switch delimiterCommand(at: scan, final: final) {
                    case .wait:
                        break scanning
                    case .command(let newDelimiter, let next):
                        emit(upTo: scan)
                        if isSQLite {
                            refusedDelimiterLine = droppedLines + buffer[..<scan].count(where: { $0 == 10 }) + 1
                            return out
                        }
                        delimiter = newDelimiter
                        scan = next
                        start = next
                        atLineStart = true
                        continue
                    case .none:
                        break
                    }
                }
                atLineStart = false
                switch byte {
                case 39, 34, 96:                                     // ' " `
                    state = .quote(byte)
                    markCode()
                    scan += 1
                    continue
                case 91 where isSQLite:                              // [name]
                    state = .quote(byte)
                    markCode()
                    scan += 1
                    continue
                case 35 where !isSQLite:                             // #
                    state = .lineComment
                    scan += 1
                    continue
                case 45:                                             // "-- " or "--" before a line end
                    if scan + 2 >= count && !final { break scanning }
                    if scan + 1 < count, buffer[scan + 1] == 45,
                       scan + 2 >= count || [32, 9, 10, 13].contains(buffer[scan + 2]) {
                        state = .lineComment
                        scan += 2
                        continue
                    }
                case 47:                                             // /* */, or /*! */ which runs
                    if scan + 2 >= count && !final { break scanning }
                    if scan + 1 < count, buffer[scan + 1] == 42 {
                        if scan + 2 < count, buffer[scan + 2] == 33, !isSQLite { markCode() }
                        state = .blockComment
                        scan += 2
                        continue
                    }
                default:
                    break
                }
                switch matchesDelimiter(at: scan, final: final) {
                case .wait:
                    break scanning
                case .yes:
                    if isSQLite, hasCode, !isComplete(codeStart, scan + 1) {
                        // A ; inside a trigger's BEGIN … END.
                        scan += 1
                        continue
                    }
                    emit(upTo: scan)
                    scan += delimiter.count
                    start = scan
                    continue
                case .no:
                    markCode()
                    scan += 1
                }
            }
        }

        if final {
            emit(upTo: count)
            buffer.removeAll()
            scan = 0
            start = 0
        } else if start > 0 {
            if isSQLite { droppedLines += buffer[..<start].count(where: { $0 == 10 }) }
            buffer.removeFirst(start)
            scan -= start
            codeStart = max(0, codeStart - start)
            start = 0
        }
        return out
    }

    /// SQLite: the bytes make a whole statement, by sqlite3_complete. Only a
    /// CREATE can hold a trigger's body, so other statements end at their first `;`.
    private func isComplete(_ from: Int, _ to: Int) -> Bool {
        let create = Array("CREATE".utf8)
        guard to - from > create.count,
              zip(buffer[from..<from + create.count], create).allSatisfy({ ($0 >= 97 && $0 <= 122 ? $0 - 32 : $0) == $1 })
        else { return true }
        var text = Array(buffer[from..<to])
        text.append(0)
        return text.withUnsafeBufferPointer { bytes in
            bytes.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { sqlite3_complete($0) != 0 }
        }
    }

    private enum Match { case yes, no, wait }

    private func matchesDelimiter(at offset: Int, final: Bool) -> Match {
        for (k, byte) in delimiter.enumerated() {
            guard offset + k < buffer.count else { return final ? .no : .wait }
            if buffer[offset + k] != byte { return .no }
        }
        return .yes
    }

    private enum Command { case command([UInt8], Int), none, wait }

    /// "DELIMITER //" from `offset` to the end of its line: the new delimiter and
    /// the offset after the line.
    private func delimiterCommand(at offset: Int, final: Bool) -> Command {
        let keyword = Array("DELIMITER".utf8)
        var k = offset
        for letter in keyword {
            guard k < buffer.count else { return final ? .none : .wait }
            let byte = buffer[k]
            let upper = byte >= 97 && byte <= 122 ? byte - 32 : byte
            if upper != letter { return .none }
            k += 1
        }
        // The whole line is needed to read the delimiter.
        guard let lineEnd = buffer[k...].firstIndex(of: 10) ?? (final ? buffer.count : nil) else { return .wait }
        guard k < lineEnd, buffer[k] == 32 || buffer[k] == 9 else { return .none }
        while k < lineEnd, buffer[k] == 32 || buffer[k] == 9 { k += 1 }
        let begin = k
        while k < lineEnd, ![32, 9, 13].contains(buffer[k]) { k += 1 }
        guard k > begin else { return .none }
        return .command(Array(buffer[begin..<k]), min(buffer.count, lineEnd + 1))
    }

    private func trimmed(_ from: Int, _ to: Int) -> [UInt8]? {
        var first = from
        var last = to
        func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
        while first < last, isSpace(buffer[first]) { first += 1 }
        while last > first, isSpace(buffer[last - 1]) { last -= 1 }
        return last > first ? Array(buffer[first..<last]) : nil
    }
}
