import Foundation
import Testing
@testable import QuarryKit

@Suite("Field types")
struct FieldTypeTests {
    @Test(arguments: [
        ("int(10) unsigned", "int", "10", true, false),
        ("int(10) unsigned zerofill", "int", "10", true, true),
        ("varchar(120)", "varchar", "120", false, false),
        ("decimal(10,2)", "decimal", "10,2", false, false),
        ("enum('draft','active','re)tired')", "enum", "'draft','active','re)tired'", false, false),
        ("datetime", "datetime", "", false, false),
        ("bigint unsigned", "bigint", "", true, false),
        ("bit(8)", "bit", "8", false, false),
    ])
    func parses(type: String, base: String, length: String, unsigned: Bool, zerofill: Bool) {
        let parsed = FieldInfo.parseType(type)
        #expect(parsed.base == base)
        #expect(parsed.length == length)
        #expect(parsed.unsigned == unsigned)
        #expect(parsed.zerofill == zerofill)
    }
}

@Suite("Objects")
struct ObjectTests {
    @Test func kindsFromServer() {
        #expect(ObjectKind(serverType: "BASE TABLE") == .table)
        #expect(ObjectKind(serverType: "VIEW") == .view)
        #expect(ObjectKind(serverType: "PROCEDURE") == .procedure)
        #expect(ObjectKind(serverType: "FUNCTION") == .function)
        #expect(ObjectKind(serverType: "SOMETHING") == nil)
    }

    @Test func filter() {
        let names = ["customers", "orders", "order_items", "order_totals", "products"]
        let objects = names.map { DBObject(name: $0, kind: .table) }
        #expect(objects.filter { $0.matches("ORD") }.map(\.name) == ["orders", "order_items", "order_totals"])
        #expect(objects.filter { $0.matches("  ") }.count == 5)
    }
}

@Suite("Paging")
struct PagingTests {
    @Test func math() {
        let paging = Paging(total: 48_213, pageSize: 1000)
        #expect(paging.pageCount == 49)
        #expect(paging.label == "Rows 1–1,000 of 48,213")
        let last = paging.moved(by: 100)
        #expect(last.page == 48)
        #expect(last.offset == 48_000)
        #expect(last.label == "Rows 48,001–48,213 of 48,213")
        #expect(!last.hasNext && last.hasPrevious)
        #expect(Paging(total: 0, pageSize: 1000).label == "No Rows")
    }

    @Test func pageSQL() {
        #expect(MySQLDialect().pageSQL(table: "events", database: "d", orderBy: "id", ascending: false, offset: 2000, limit: 1000)
                == "SELECT * FROM `d`.`events` ORDER BY `id` DESC LIMIT 2000, 1000")
        #expect(MySQLDialect().pageSQL(table: "t", database: "d", orderBy: nil, ascending: true, offset: 0, limit: 10)
                == "SELECT * FROM `d`.`t` LIMIT 0, 10")
    }
}

@Suite("Connection details")
struct ConnectionDetailsTests {
    @Test func defaults() {
        let config = ConnectionDetails(host: " ", port: "", user: "root", password: "", database: "").driverConfiguration
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 3306)
        #expect(config.password == nil)
        #expect(config.database == nil)
    }

    @Test func typedValues() {
        let config = ConnectionDetails(host: "db.local", port: "3399", user: " quarry ", password: "p", database: "quarry_demo").driverConfiguration
        #expect(config == .init(host: "db.local", port: 3399, user: "quarry", password: "p", database: "quarry_demo"))
    }

    @Test func socket() {
        let config = ConnectionDetails(transport: .socket, host: "ignored", socket: " /tmp/x.sock ", user: "u").driverConfiguration
        #expect(config.socketPath == "/tmp/x.sock")
        #expect(config.location == "/tmp/x.sock")
        #expect(ConnectionDetails(transport: .socket, socket: "~/s.sock").driverConfiguration.socketPath
                == NSHomeDirectory() + "/s.sock")
        #expect(ConnectionDetails(host: "h", port: "1").driverConfiguration.socketPath == nil)
        #expect(ConnectionDetails(transport: .socket).displayName == "localhost")
        // A socket ignores the port, so a bad one left over from TCP/IP is no problem.
        #expect(ConnectionDetails(transport: .socket, port: "99999", user: "a").problem == nil)
    }

    @Test func defaultSocket() {
        #expect(ConnectionDetails.defaultSocketPath { _ in false } == "/tmp/mysql.sock")
        #expect(ConnectionDetails.defaultSocketPath { $0.hasPrefix("/opt/homebrew") } == "/opt/homebrew/var/mysql/mysql.sock")
    }

    @Test func problems() {
        #expect(ConnectionDetails(user: "").problem == "Enter a user name.")
        #expect(ConnectionDetails(port: "99999", user: "a").problem != nil)
        #expect(ConnectionDetails(port: "3306", user: "a").problem == nil)
    }

    @Test func displayName() {
        #expect(ConnectionDetails(name: "Local", host: "x").displayName == "Local")
        #expect(ConnectionDetails(host: "").displayName == "127.0.0.1")
    }
}

@Suite("Values")
struct ValueTests {
    @Test func display() {
        #expect(CellValue.null.displayText == "NULL")
        #expect(CellValue.binary(Data([1, 2, 3])).displayText == "BLOB 3 bytes")
        #expect(CellValue.binary(Data(count: 12_288)).displayText == "BLOB 12 KB")
        #expect(CellValue.null.plainText == nil)
    }

    @Test func serverLine() {
        #expect(ServerMessage.line(in: "You have an error in your SQL syntax; ... near 'oops' at line 2") == 2)
        #expect(ServerMessage.line(in: "Unknown table") == nil)
    }

    @Test func returnsRows() {
        #expect(DatabaseClient.returnsRows("  select 1"))
        #expect(DatabaseClient.returnsRows("(SELECT 1) UNION (SELECT 2)"))
        #expect(!DatabaseClient.returnsRows("UPDATE t SET a = 1"))
    }
}
