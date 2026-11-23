import Foundation

/// The text of a CSV, JSON or XML export (S-042): rows of plain values,
/// written piece by piece. Pure, so the quoting and types are unit tested.
public enum DataExport {
    public enum Format: String, Sendable, Hashable, CaseIterable, Identifiable {
        case csv, json, xml

        public var id: String { rawValue }
        public var fileExtension: String { rawValue }
        /// "CSV", "JSON", "XML".
        public var title: String { rawValue.uppercased() }
    }

    /// Sequel Pro's CSV choices. A value is enclosed unless it is a number in
    /// a numeric column or NULL; with no enclosure, separators and line ends
    /// inside a value are escaped instead.
    public struct CSVOptions: Sendable, Hashable {
        public var fieldSeparator = ","
        public var enclosure = "\""
        public var escape = "\""
        public var lineEnd = "\n"
        public var header = true
        public var nullText = "NULL"

        public init(fieldSeparator: String = ",", enclosure: String = "\"", escape: String = "\"",
                    lineEnd: String = "\n", header: Bool = true, nullText: String = "NULL") {
            self.fieldSeparator = fieldSeparator
            self.enclosure = enclosure
            self.escape = escape
            self.lineEnd = lineEnd
            self.header = header
            self.nullText = nullText
        }
    }

    /// Where the rows come from, which shapes the file around them.
    public enum Shape: Sendable, Hashable {
        /// Whole tables of `database`: JSON is an object keyed by table name,
        /// XML is mysqldump's `<database>` with a `<table_data>` per table.
        case tables(database: String)
        /// One set of rows (filtered content, a query result): JSON is an
        /// array, XML a `<resultset>` naming the statement.
        case rows(statement: String)
    }

    // MARK: Values

    /// A value as text, or nil for NULL. Bytes that aren't text are 0x…;
    /// a BIT column's value is its number.
    public static func text(_ value: CellValue, column: ResultColumn) -> String? {
        if let width = column.bitWidth, !value.isNull {
            return String(BitValue(width: width, value: value).raw)
        }
        switch value {
        case .flag(let on): return on ? "1" : "0"
        default: return value.plainText
        }
    }

    /// Writes a number bare only when the column is numeric and the text is a number.
    static func isNumber(_ value: CellValue, column: ResultColumn) -> Bool {
        guard column.isNumeric || column.bitWidth != nil else { return false }
        if column.bitWidth != nil { return !value.isNull }
        guard case .text(let text) = value else { return false }
        return isJSONNumber(text)
    }

    /// -12, 0.5, 1e10: JSON's number grammar, so the bare text parses everywhere.
    static func isJSONNumber(_ text: String) -> Bool {
        text.wholeMatch(of: /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/) != nil
    }

    // MARK: CSV

    public static func csvField(_ value: CellValue, column: ResultColumn, options: CSVOptions) -> String {
        guard let text = text(value, column: column) else { return options.nullText }
        if isNumber(value, column: column) { return text }
        return csvQuoted(text, options: options)
    }

    static func csvQuoted(_ text: String, options: CSVOptions) -> String {
        let enclosure = options.enclosure
        let escape = options.escape
        if text.isEmpty { return enclosure + enclosure }
        var out = text
        if !escape.isEmpty, escape != enclosure {
            out = out.replacingOccurrences(of: escape, with: escape + escape)
        }
        if enclosure.isEmpty {
            guard !escape.isEmpty else { return out }
            for special in [options.fieldSeparator, options.lineEnd] where !special.isEmpty {
                out = out.replacingOccurrences(of: special, with: escape + special)
            }
            return out
        }
        out = out.replacingOccurrences(of: enclosure, with: (escape.isEmpty ? enclosure : escape) + enclosure)
        return enclosure + out + enclosure
    }

    public static func csvRow(_ row: [CellValue], columns: [ResultColumn], options: CSVOptions) -> String {
        zip(row, columns).map { csvField($0, column: $1, options: options) }
            .joined(separator: options.fieldSeparator) + options.lineEnd
    }

    public static func csvHeader(_ columns: [ResultColumn], options: CSVOptions) -> String {
        columns.map { csvQuoted($0.name, options: options) }.joined(separator: options.fieldSeparator) + options.lineEnd
    }

    // MARK: JSON

    /// A JSON string literal: quotes, backslashes and control characters escaped.
    public static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// One value as JSON: null, a bare number, or a string.
    public static func jsonValue(_ value: CellValue, column: ResultColumn) -> String {
        guard let text = text(value, column: column) else { return "null" }
        return isNumber(value, column: column) ? text : jsonString(text)
    }

    /// `{"id": 1, "name": "Ada", "note": null}`.
    public static func jsonObject(_ row: [CellValue], columns: [ResultColumn]) -> String {
        "{" + zip(row, columns).map { jsonString($1.name) + ": " + jsonValue($0, column: $1) }
            .joined(separator: ", ") + "}"
    }

    // MARK: XML

    /// Text safe inside an element or an attribute. Characters XML 1.0 can't
    /// hold at all (most control characters) become U+FFFD.
    public static func xmlEscaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF:
                out += "\u{FFFD}"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// One row as mysqldump --xml writes it; NULL is `xsi:nil="true"`.
    public static func xmlRow(_ row: [CellValue], columns: [ResultColumn], indent: String) -> String {
        var out = indent + "<row>\n"
        for (value, column) in zip(row, columns) {
            out += indent + "\t<field name=\"" + xmlEscaped(column.name) + "\""
            if let text = text(value, column: column) {
                out += ">" + xmlEscaped(text) + "</field>\n"
            } else {
                out += " xsi:nil=\"true\" />\n"
            }
        }
        return out + indent + "</row>\n"
    }

    static let xmlDeclaration = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
    static let xsi = "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""

    // MARK: Writer

    /// Writes a whole file: `start()`, then for each table `begin`, `append`
    /// page by page, `end`, and last `finish()`. Each returns the text to write.
    public struct Writer: Sendable {
        public let format: Format
        public let shape: Shape
        public let csv: CSVOptions
        private var columns: [ResultColumn] = []
        private var tablesWritten = 0
        private var rowsInTable = 0

        public init(format: Format, shape: Shape, csv: CSVOptions = CSVOptions()) {
            self.format = format
            self.shape = shape
            self.csv = csv
        }

        /// Starts a file; a per-table export starts each of its files.
        public mutating func start() -> String {
            tablesWritten = 0
            return switch (format, shape) {
            case (.csv, _): ""
            case (.json, .tables): "{\n"
            case (.json, .rows): ""
            case (.xml, .tables(let database)):
                xmlDeclaration + "<mysqldump \(xsi)>\n<database name=\"\(xmlEscaped(database))\">\n"
            case (.xml, .rows(let statement)):
                xmlDeclaration + "<resultset statement=\"\(xmlEscaped(statement))\" \(xsi)>\n"
            }
        }

        /// Starts a table (or the one set of rows) with these columns.
        public mutating func begin(_ name: String, columns: [ResultColumn]) -> String {
            self.columns = columns
            rowsInTable = 0
            defer { tablesWritten += 1 }
            switch (format, shape) {
            case (.csv, _):
                // Tables in one file are a blank line apart, each with its own header.
                let gap = tablesWritten > 0 ? csv.lineEnd : ""
                return gap + (csv.header ? DataExport.csvHeader(columns, options: csv) : "")
            case (.json, .tables):
                return (tablesWritten > 0 ? ",\n" : "") + "\t" + jsonString(name) + ": ["
            case (.json, .rows):
                return "["
            case (.xml, .tables):
                return "\t<table_data name=\"\(xmlEscaped(name))\">\n"
            case (.xml, .rows):
                return ""
            }
        }

        public mutating func append(_ rows: [[CellValue]]) -> String {
            var out = ""
            for row in rows {
                switch format {
                case .csv:
                    out += csvRow(row, columns: columns, options: csv)
                case .json:
                    let indent = isRows ? "\t" : "\t\t"
                    out += (rowsInTable > 0 ? ",\n" : "\n") + indent + jsonObject(row, columns: columns)
                case .xml:
                    out += xmlRow(row, columns: columns, indent: isRows ? "\t" : "\t\t")
                }
                rowsInTable += 1
            }
            return out
        }

        public mutating func end() -> String {
            switch (format, shape) {
            case (.csv, _): return ""
            case (.json, .tables): return rowsInTable > 0 ? "\n\t]" : "]"
            case (.json, .rows): return rowsInTable > 0 ? "\n]" : "]"
            case (.xml, .tables): return "\t</table_data>\n"
            case (.xml, .rows): return ""
            }
        }

        public func finish() -> String {
            switch (format, shape) {
            case (.csv, _): ""
            case (.json, .tables): "\n}\n"
            case (.json, .rows): "\n"
            case (.xml, .tables): "</database>\n</mysqldump>\n"
            case (.xml, .rows): "</resultset>\n"
            }
        }

        private var isRows: Bool {
            if case .rows = shape { return true }
            return false
        }
    }
}
