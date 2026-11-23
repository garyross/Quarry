import Foundation

/// One line in the Console (S-039): a statement Quarry sent, or the error a
/// statement got back, with when, on which connection and in which database.
public struct ConsoleMessage: Sendable, Identifiable, Equatable {
    public let id: Int
    public let date: Date
    /// The connection's name, as the window's subtitle shows it.
    public let connection: String
    /// The database selected when the statement ran; nil before one is chosen.
    public let database: String?
    /// The statement on one line, ending in ";", or an error as a /* comment */.
    public let text: String
    public let isError: Bool

    public init(id: Int, date: Date, connection: String, database: String?, text: String, isError: Bool) {
        self.id = id
        self.date = date
        self.connection = connection
        self.database = database
        self.text = text
        self.isError = isError
    }

    /// Longer statements (a big INSERT of bytes) are cut here, so the log stays small.
    public static let maximumLength = 16_384

    /// A statement as the Console shows it: trimmed, on one line, ending in ";",
    /// as Sequel Pro writes it.
    public static func statementText(_ sql: String) -> String {
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") { text.removeLast() }
        text = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if text.count > maximumLength { text = String(text.prefix(maximumLength)) + "…" }
        return text + ";"
    }

    /// An error as the Console shows it, a comment so a saved log still runs.
    public static func errorText(_ error: DatabaseError) -> String {
        let message = error.message.replacingOccurrences(of: "*/", with: "* /")
            .replacingOccurrences(of: "\n", with: " ")
        if let code = error.code { return "/* ERROR \(code): \(message) */" }
        return "/* ERROR: \(message) */"
    }
}

/// What the Console shows: the filter field's text and the gear menu's
/// Show SELECT/SHOW Statements and Show HELP Statements (S-039).
public struct ConsoleFilter: Sendable, Equatable {
    public var text: String
    public var showsSelectAndShow: Bool
    public var showsHelp: Bool

    public init(text: String = "", showsSelectAndShow: Bool = true, showsHelp: Bool = true) {
        self.text = text
        self.showsSelectAndShow = showsSelectAndShow
        self.showsHelp = showsHelp
    }

    /// True when nothing is hidden.
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty && showsSelectAndShow && showsHelp
    }

    public func matches(_ message: ConsoleMessage) -> Bool {
        let query = text.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty, message.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }
        // Errors stay with their statement: only statements are hidden by kind.
        guard !message.isError else { return true }
        let verb = Self.verb(message.text)
        if !showsSelectAndShow, verb == "SELECT" || verb == "SHOW" { return false }
        if !showsHelp, verb == "HELP" { return false }
        return true
    }

    public func apply(_ messages: [ConsoleMessage]) -> [ConsoleMessage] {
        isEmpty ? messages : messages.filter(matches)
    }

    /// The statement's first word, upper-cased; "(SELECT …" counts as SELECT.
    static func verb(_ text: String) -> String {
        text.drop { $0.isWhitespace || $0 == "(" }.prefix { $0.isLetter }.uppercased()
    }
}

/// Text for Copy and Save As…: each message on its own line, the shown
/// columns before it in a comment, so the file runs as SQL (S-039).
public enum ConsoleText {
    public struct Columns: Sendable, Equatable {
        public var time: Bool
        public var connection: Bool
        public var database: Bool
        public init(time: Bool = true, connection: Bool = true, database: Bool = true) {
            self.time = time
            self.connection = connection
            self.database = database
        }
    }

    public static func text(_ messages: [ConsoleMessage], columns: Columns, time: (Date) -> String) -> String {
        messages.map { message in
            var parts: [String] = []
            if columns.time { parts.append(time(message.date)) }
            if columns.connection, !message.connection.isEmpty { parts.append(message.connection) }
            if columns.database, let database = message.database, !database.isEmpty { parts.append(database) }
            let prefix = parts.isEmpty ? "" : "/* \(parts.joined(separator: " ")) */ "
            return prefix + message.text + "\n"
        }.joined()
    }
}

/// Every statement every connection sent, for the Console (S-039). Shared by
/// all windows, as Sequel Pro's console is. `DatabaseClient` adds to it;
/// the app reads it through `onChange`.
public final class ConsoleLog: @unchecked Sendable {
    public static let shared = ConsoleLog()

    /// Older messages are dropped past this many.
    public static let limit = 5_000

    private let lock = NSLock()
    private var stored: [ConsoleMessage] = []
    private var nextID = 0
    private var handler: (@Sendable () -> Void)?
    private var notifyPending = false

    private var logsStatementsValue = true

    public init() {}

    /// Settings > General (S-054): off, only errors are logged.
    public var logsStatements: Bool {
        get { lock.withLock { logsStatementsValue } }
        set { lock.withLock { logsStatementsValue = newValue } }
    }

    public var messages: [ConsoleMessage] {
        lock.withLock { stored }
    }

    /// Called once after one or more messages arrive (or Clear), from any
    /// thread; read `messages` there. Many statements in a row call it once.
    public func onChange(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }

    public func add(connection: String, database: String?, text: String, isError: Bool = false, date: Date = .now) {
        let notify: (@Sendable () -> Void)? = lock.withLock {
            guard isError || logsStatementsValue else { return nil }
            stored.append(ConsoleMessage(id: nextID, date: date, connection: connection, database: database,
                                         text: text, isError: isError))
            nextID += 1
            if stored.count > Self.limit { stored.removeFirst(stored.count - Self.limit) }
            return takeNotify()
        }
        notify?()
    }

    public func clear() {
        let notify = lock.withLock {
            stored.removeAll()
            return takeNotify()
        }
        notify?()
    }

    /// The reader calls this when it has read `messages`, so the next message notifies again.
    public func didRead() {
        lock.withLock { notifyPending = false }
    }

    private func takeNotify() -> (@Sendable () -> Void)? {
        guard !notifyPending, let handler else { return nil }
        notifyPending = true
        return handler
    }
}
