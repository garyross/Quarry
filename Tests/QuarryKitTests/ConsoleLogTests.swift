import Foundation
import Testing
@testable import QuarryKit

struct ConsoleLogTests {
    private func message(_ text: String, error: Bool = false, id: Int = 0) -> ConsoleMessage {
        ConsoleMessage(id: id, date: Date(timeIntervalSince1970: 0), connection: "Local", database: "quarry_demo",
                       text: text, isError: error)
    }

    @Test func statementsGoOnOneLineWithASemicolon() {
        #expect(ConsoleMessage.statementText("  SELECT *\n  FROM orders;\n") == "SELECT *   FROM orders;")
        #expect(ConsoleMessage.statementText("SHOW TABLES") == "SHOW TABLES;")
        let long = ConsoleMessage.statementText(String(repeating: "x", count: ConsoleMessage.maximumLength + 10))
        #expect(long.hasSuffix("…;"))
    }

    @Test func errorsAreComments() {
        let text = ConsoleMessage.errorText(DatabaseError(message: "Bad */ syntax", code: 1064))
        #expect(text == "/* ERROR 1064: Bad * / syntax */")
    }

    @Test func hidingSelectAndShow() {
        let all = [message("SELECT 1;"), message("(SELECT 2) UNION (SELECT 3);"), message("show tables;"),
                   message("UPDATE t SET a = 1;"), message("/* ERROR 1064: x */", error: true), message("HELP 'select';")]
        let filter = ConsoleFilter(showsSelectAndShow: false)
        #expect(filter.apply(all).map(\.text) == ["UPDATE t SET a = 1;", "/* ERROR 1064: x */", "HELP 'select';"])
        let noHelp = ConsoleFilter(showsHelp: false)
        #expect(noHelp.apply(all).count == 5)
        #expect(ConsoleFilter().apply(all).count == 6)
    }

    @Test func filterTextIgnoresCase() {
        let all = [message("SELECT * FROM orders;"), message("UPDATE customers SET a = 1;")]
        #expect(ConsoleFilter(text: "ORDERS").apply(all).map(\.text) == ["SELECT * FROM orders;"])
    }

    @Test func copyTextCommentsTheColumns() {
        let messages = [message("SELECT 1;"), message("SELECT 2;")]
        let text = ConsoleText.text(messages, columns: .init(time: true, connection: true, database: false)) { _ in "10:00:00" }
        #expect(text == "/* 10:00:00 Local */ SELECT 1;\n/* 10:00:00 Local */ SELECT 2;\n")
        let bare = ConsoleText.text(messages, columns: .init(time: false, connection: false, database: false)) { _ in "" }
        #expect(bare == "SELECT 1;\nSELECT 2;\n")
    }

    @Test func usedDatabase() {
        #expect(DatabaseClient.usedDatabase("USE `quarry``demo`;") == "quarry`demo")
        #expect(DatabaseClient.usedDatabase("use quarry_demo") == "quarry_demo")
        #expect(DatabaseClient.usedDatabase("USER()") == nil)
        #expect(DatabaseClient.usedDatabase("SELECT 1") == nil)
    }

    @Test func logKeepsTheNewestAndNotifiesOnce() {
        let log = ConsoleLog()
        let count = Counter()
        log.onChange { count.bump() }
        for index in 0..<(ConsoleLog.limit + 5) {
            log.add(connection: "Local", database: nil, text: "SELECT \(index);")
        }
        #expect(count.value == 1)
        #expect(log.messages.count == ConsoleLog.limit)
        #expect(log.messages.first?.text == "SELECT 5;")
        log.didRead()
        log.clear()
        #expect(count.value == 2)
        #expect(log.messages.isEmpty)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
