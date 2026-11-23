import Foundation

/// One record of a CSV file: its fields, nil for NULL.
public typealias CSVRow = [String?]

/// Reads CSV records as a file's bytes arrive, a buffer at a time (S-045),
/// with Sequel Pro's options: fields separated, enclosed and escaped by the
/// given text, and records ending with the given line end. A separator,
/// enclosure or line end split across two buffers is waited for, never cut.
/// It works on bytes, so ASCII-compatible encodings (UTF-8, Latin 1, Windows
/// 1252) parse alike and each record is decoded once it is whole.
///
/// - An enclosed field may hold separators and line ends. Inside it, the
///   enclosure is written twice (an escape of `"` or of the enclosure
///   itself means doubling) or after the escape, such as `\`.
/// - An unenclosed `\N`, or the NULL text (`NULL` by default), is NULL.
/// - With LF line ends, a CR before the LF is dropped, so Windows files read too.
/// - Blank lines are skipped.
public struct CSVStreamParser: Sendable {
    private enum Match { case yes, no, partial }

    public let options: DataExport.CSVOptions
    public let encoding: String.Encoding
    private let separator: [UInt8]
    private let enclosure: [UInt8]
    private let escape: [UInt8]
    private let lineEnd: [UInt8]
    private let nullBytes: [UInt8]
    /// The escape is its own character, not the doubled enclosure.
    private let escapeIsDistinct: Bool

    private var buffer: [UInt8] = []
    private var scan = 0
    private var row: [[UInt8]?] = []
    private var field: [UInt8] = []
    /// The field's bytes as written, for the NULL check of an unenclosed field.
    private var raw: [UInt8] = []
    private var fieldStarted = false
    private var quoted = false
    private var inQuotes = false
    /// Records read, blank lines not counted; the next record's number is this plus one.
    public private(set) var records = 0

    public init(options: DataExport.CSVOptions, encoding: String.Encoding = .utf8) {
        self.options = options
        self.encoding = encoding
        separator = Array(options.fieldSeparator.utf8)
        enclosure = Array(options.enclosure.utf8)
        escape = Array(options.escape.utf8)
        lineEnd = Array(options.lineEnd.isEmpty ? "\n".utf8 : options.lineEnd.utf8)
        nullBytes = Array(options.nullText.utf8)
        // A `"` escape means doubling, as in the Export sheet's "Doubling Them",
        // whatever the enclosure is.
        escapeIsDistinct = !options.escape.isEmpty && options.escape != options.enclosure && options.escape != "\""
    }

    /// Adds `bytes` and returns the records they complete.
    public mutating func append(_ bytes: some Sequence<UInt8>) throws -> [CSVRow] {
        buffer.append(contentsOf: bytes)
        return try parse(final: false)
    }

    /// The end of the file: the last record, even without a line end.
    public mutating func finish() throws -> [CSVRow] {
        var out = try parse(final: true)
        if fieldStarted || !row.isEmpty {
            endField(atLineEnd: true)
            if let record = try endRow() { out.append(record) }
        }
        return out
    }

    /// Every record of `text`, for tests and the clipboard.
    public static func records(in text: String, options: DataExport.CSVOptions) throws -> [CSVRow] {
        var parser = CSVStreamParser(options: options)
        return try parser.append(Array(text.utf8)) + parser.finish()
    }

    private func match(_ token: [UInt8], at index: Int, final: Bool) -> Match {
        guard !token.isEmpty else { return .no }
        for offset in token.indices {
            let position = index + offset
            if position >= buffer.count { return final ? .no : .partial }
            if buffer[position] != token[offset] { return .no }
        }
        return .yes
    }

    private mutating func parse(final: Bool) throws -> [CSVRow] {
        var out: [CSVRow] = []
        scanning: while scan < buffer.count {
            if inQuotes {
                if escapeIsDistinct {
                    switch match(escape, at: scan, final: final) {
                    case .partial: break scanning
                    case .yes:
                        let after = scan + escape.count
                        if after >= buffer.count {
                            if !final { break scanning }
                            field += escape
                            scan = after
                        } else {
                            field.append(buffer[after])
                            scan = after + 1
                        }
                        continue scanning
                    case .no: break
                    }
                }
                switch match(enclosure, at: scan, final: final) {
                case .partial: break scanning
                case .yes:
                    let after = scan + enclosure.count
                    if !escapeIsDistinct {
                        switch match(enclosure, at: after, final: final) {
                        case .partial: break scanning
                        case .yes:
                            field += enclosure
                            scan = after + enclosure.count
                            continue scanning
                        case .no: break
                        }
                    }
                    inQuotes = false
                    scan = after
                    continue scanning
                case .no:
                    field.append(buffer[scan])
                    scan += 1
                    continue scanning
                }
            }

            if !fieldStarted {
                switch match(enclosure, at: scan, final: final) {
                case .partial: break scanning
                case .yes:
                    fieldStarted = true
                    quoted = true
                    inQuotes = true
                    scan += enclosure.count
                    continue scanning
                case .no: break
                }
            }
            switch match(separator, at: scan, final: final) {
            case .partial: break scanning
            case .yes:
                endField(atLineEnd: false)
                scan += separator.count
                continue scanning
            case .no: break
            }
            switch match(lineEnd, at: scan, final: final) {
            case .partial: break scanning
            case .yes:
                endField(atLineEnd: true)
                scan += lineEnd.count
                if let record = try endRow() { out.append(record) }
                continue scanning
            case .no: break
            }
            if escapeIsDistinct, !quoted {
                switch match(escape, at: scan, final: final) {
                case .partial: break scanning
                case .yes:
                    let after = scan + escape.count
                    fieldStarted = true
                    raw += escape
                    if after >= buffer.count {
                        if !final { break scanning }
                        field += escape
                        scan = after
                    } else {
                        raw.append(buffer[after])
                        field.append(buffer[after])
                        scan = after + 1
                    }
                    continue scanning
                case .no: break
                }
            }
            fieldStarted = true
            if !quoted { raw.append(buffer[scan]) }
            field.append(buffer[scan])
            scan += 1
        }
        buffer.removeFirst(scan)
        scan = 0
        return out
    }

    private mutating func endField(atLineEnd: Bool) {
        if atLineEnd, !quoted, lineEnd == [10], field.last == 13 {
            field.removeLast()
            raw.removeLast()
        }
        if !quoted, raw == [92, 78] || (!nullBytes.isEmpty && raw == nullBytes) {
            row.append(nil)
        } else {
            row.append(field)
        }
        field = []
        raw = []
        fieldStarted = false
        quoted = false
        inQuotes = false
    }

    /// The finished record, decoded; nil for a blank line.
    private mutating func endRow() throws -> CSVRow? {
        defer { row = [] }
        if row.count == 1, row[0]?.isEmpty == true { return nil }
        records += 1
        return try row.map { bytes in
            guard let bytes else { return nil }
            guard let text = String(bytes: bytes, encoding: encoding) else {
                throw DatabaseError(message: "Record \(records) isn’t valid \(String.localizedName(of: encoding)). "
                                    + "Choose the file’s encoding and import again.")
            }
            return text
        }
    }
}
