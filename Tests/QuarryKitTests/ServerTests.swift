import Foundation
import Testing
@testable import QuarryKit
import QuarryTestSupport

/// Runs against the private test server (tools/testdb.sh start). Skipped when it is not running.
@Suite("Test server", .enabled(if: TestServer.isRunning))
struct ServerTests {
    @Test func connectsAndReadsTheFixture() async throws {
        let client = try await DatabaseClient.connect(TestServer.details)
        #expect(client.serverDescription.hasPrefix("MariaDB") || client.serverDescription.hasPrefix("MySQL"))
        let databases = try await client.databases()
        #expect(databases.contains("quarry_demo"))
        let objects = try await client.objects(in: "quarry_demo")
        #expect(objects.contains(DBObject(name: "orders", kind: .table)))
        #expect(objects.contains(DBObject(name: "order_totals", kind: .view)))
        #expect(objects.contains(DBObject(name: "customer_orders", kind: .procedure)))
        #expect(objects.contains(DBObject(name: "order_count", kind: .function)))
        await client.close()
    }

    @Test func connectsOverTheSocket() async throws {
        let client = try await DatabaseClient.connect(TestServer.socketDetails)
        let rows = try await client.run("SELECT CURRENT_USER()")
        #expect(rows.string(0, "CURRENT_USER()") == "quarry@localhost")
        await client.close()
    }

    /// S-036: KILL QUERY from a second connection stops SLEEP(30) at once, and the connection still works.
    @Test func cancelStopsARunningQuery() async throws {
        let client = try await DatabaseClient.connect(TestServer.details)
        #expect(client.connectionID != nil)
        let clock = ContinuousClock()
        let start = clock.now
        let running = Task { try await client.run("SELECT SLEEP(30)") }
        try await Task.sleep(for: .milliseconds(300))
        try await client.cancelRunningQuery()
        _ = try? await running.value
        #expect(clock.now - start < .seconds(2))
        let after = try await client.run("SELECT 1 AS one")
        #expect(after.string(0, "one") == "1")
        await client.close()
    }

    /// S-050: a connection killed on the server reports itself lost; a cancelled query does not.
    @Test func killedConnectionIsReportedLost() async throws {
        let client = try await DatabaseClient.connect(TestServer.details)
        let killer = try await DatabaseClient.connect(TestServer.details)
        let id = try #require(client.connectionID)
        _ = try await killer.run("KILL \(id)")
        await killer.close()
        let error = await #expect(throws: DatabaseError.self) { try await client.run("SELECT 1") }
        #expect(error?.message == "The connection to the server was lost.", "\(error?.message ?? "")")
        #expect(await client.wasLost)
        await client.untilLost()  // returns at once once lost
        await client.close()
    }

    @Test func missingSocketSaysSo() async {
        var details = TestServer.socketDetails
        details.socket = "/tmp/quarry-no-such.sock"
        let error = await #expect(throws: DatabaseError.self) { try await DatabaseClient.connect(details) }
        #expect(error?.message == "There is no socket at /tmp/quarry-no-such.sock.", "\(error?.message ?? "")")
    }

    @Test func wrongPasswordIsAccessDenied() async {
        var details = TestServer.details
        details.password = "wrong"
        do {
            _ = try await DatabaseClient.connect(details)
            Issue.record("connected with a wrong password")
        } catch let error as DatabaseError {
            #expect(error.code == 1045)
            #expect(error.message.contains("Access denied"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func fieldsAndValues() async throws {
        let client = try await DatabaseClient.connect(TestServer.details)
        let fields = try await client.fields(of: "products", in: "quarry_demo")
        let price = try #require(fields.first { $0.name == "price" })
        #expect(price.baseType == "decimal" && price.length == "10,2")
        let rows = try await client.page(of: "products", in: "quarry_demo", orderBy: "id", ascending: true, offset: 0, limit: 10)
        let thumbnail = try #require(rows.columns.firstIndex { $0.name == "thumbnail" })
        #expect(rows.rows[0][thumbnail] == .binary(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])))
        #expect(rows.rows[1][thumbnail] == .null)
        let customers = try await client.page(of: "customers", in: "quarry_demo", orderBy: "id", ascending: true, offset: 9, limit: 1)
        #expect(customers.string(0, "notes") == "Unicode: こんにちは 🌸")
        await client.close()
    }

    @Test func affectedRowsAndErrors() async throws {
        let client = try await DatabaseClient.connect(TestServer.details)
        _ = try await client.run("CREATE TEMPORARY TABLE quarry_demo.tmp (a INT)")
        let insert = try await client.run("INSERT INTO quarry_demo.tmp VALUES (1), (2), (3)")
        #expect(insert.affectedRows == 3)
        let empty = try await client.run("SELECT * FROM quarry_demo.tmp WHERE a > 5")
        #expect(empty.returnsRows && empty.rows.isEmpty)
        let error = await #expect(throws: DatabaseError.self) { try await client.run("SELEC oops") }
        #expect(error?.code == 1064)
        #expect(error?.message.hasPrefix("You have an error in your SQL syntax") == true, "\(error?.message ?? "")")
        await client.close()
    }
}

/// S-041: exporting quarry_demo and loading the file into a new database gives the same rows.
@Suite("SQL export round trip", .enabled(if: TestServer.isRunning))
struct ExportServerTests {
    @Test(arguments: [SQLDump.Compression.none, .gzip])
    func exportLoadsIntoANewDatabase(compression: SQLDump.Compression) async throws {
        let client = try await DatabaseClient.connect(TestServer.details)
        let source = "quarry_demo"
        let target = "quarry_export_test_\(compression.rawValue)"
        let objects = try await client.objects(in: source)
        let tables = objects.filter { $0.kind == .table }.map(\.name)
        let url = FileManager.default.temporaryDirectory.appending(path: "quarry-export-\(UUID().uuidString).\(compression.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try DumpFile(url: url, compression: compression)
        let exporter = try await client.secondConnection()
        do {
            try await exporter.exportSQL(objects.map { ExportItem(object: $0, part: .init()) }, from: source,
                                         options: .init(batch: .rows(1_000), compression: compression), to: file) { _ in }
        } catch {
            await exporter.close()
            await client.close()
            throw error
        }
        try file.close()
        await exporter.close()

        var text: String
        if compression == .gzip {
            let gunzip = Process()
            gunzip.executableURL = URL(filePath: "/usr/bin/gunzip")
            gunzip.arguments = ["-c", url.path]
            let pipe = Pipe()
            gunzip.standardOutput = pipe
            try gunzip.run()
            text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            gunzip.waitUntilExit()
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        #expect(!text.contains("`quarry_demo`."))

        _ = try await client.run("DROP DATABASE IF EXISTS \(SQLQuote.identifier(target))")
        _ = try await client.run("CREATE DATABASE \(SQLQuote.identifier(target))")
        do {
            try await client.runScript(text, in: target)
        } catch {
            await client.close()
            throw error
        }
        let copied = try await client.objects(in: target)
        #expect(Set(copied) == Set(objects))
        let before = try await client.fingerprint(of: tables, in: source)
        let after = try await client.fingerprint(of: tables, in: target)
        #expect(before == after)
        let triggers = try await client.triggerNames(in: target)
        #expect(!triggers.isEmpty)
        _ = try await client.run("DROP DATABASE \(SQLQuote.identifier(target))")
        await client.close()
    }
}
