import Foundation
import Testing
import QuarryKit
import QuarryControllers
import QuarryTestSupport

/// The same controllers on the test MariaDB (127.0.0.1:3399), in a database of
/// their own that each test makes and drops. Skipped when the server isn't running.
@Suite("Controllers on the test server", .enabled(if: TestServer.isRunning), .serialized)
struct MySQLControllerTests {
    static let database = "quarry_controller_tests"

    /// A fresh `people` table with three rows.
    static func connect() async throws -> DatabaseClient {
        let client = try await DatabaseClient.connect(TestServer.details)
        _ = try await client.run("DROP DATABASE IF EXISTS `\(database)`")
        _ = try await client.run("CREATE DATABASE `\(database)` CHARACTER SET utf8mb4")
        _ = try await client.run("""
            CREATE TABLE `\(database)`.`people` (
              id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
              name VARCHAR(100) NOT NULL,
              city VARCHAR(50) DEFAULT 'Oslo',
              score INT NULL
            ) ENGINE=InnoDB
            """)
        _ = try await client.run("INSERT INTO `\(database)`.`people` (name, city, score) VALUES ('Ann', 'Bergen', 3), ('Bo', 'Oslo', 1), ('Cy', 'Tromsø', 2)")
        return client
    }

    /// Runs `body` on a fresh database, then drops it and closes the connection, also when `body` throws.
    static func withPeople(_ body: (DatabaseClient) async throws -> Void) async throws {
        let client = try await connect()
        var failure: Error?
        do { try await body(client) } catch { failure = error }
        _ = try? await client.run("DROP DATABASE IF EXISTS `\(database)`")
        // MySQLNIO asserts in debug builds when a connection is never closed.
        await client.close()
        if let failure { throw failure }
    }

    static func people(_ client: DatabaseClient) async throws -> DBObject {
        try await Fixture.object("people", in: database, client: client)
    }

    @Test func contentEditsAddsAndDeletesRows() async throws {
        try await Self.withPeople { client in
            let content = ContentController(pageSize: { 1000 })
            await content.show(try await Self.people(client), in: Self.database, client: client, force: false)?.value
            #expect(content.load.error == nil)
            #expect(content.grid.rows.count == 3)

            await content.sort(by: "score", ascending: false)?.value
            #expect(content.grid.rows.first?[1] == .text("Ann"))

            let city = try #require(content.columns.firstIndex { $0.name == "city" })
            await content.edit(row: 0, column: city, to: .text("Stavanger"))?.value
            #expect(content.editError == nil)
            #expect(try await Fixture.strings("SELECT city FROM `\(Self.database)`.people WHERE name = 'Ann'", client: client) == ["Stavanger"])

            await content.addRow()?.value
            let row = try #require(content.draft?.row)
            content.edit(row: row, column: 1, to: .text("Di"))
            await content.saveDraft()?.value
            #expect(content.editError == nil)
            #expect(content.grid.rows[row][0] == .text("4"))
            #expect(content.grid.rows[row][city] == .text("Oslo"))

            content.selection = [row]
            content.requestDelete()
            await content.confirmDelete()?.value
            #expect(try await Fixture.strings("SELECT COUNT(*) FROM `\(Self.database)`.people", client: client) == ["3"])
        }
    }

    @Test func contentFiltersWithMySQLQuoting() async throws {
        try await Self.withPeople { client in
            _ = try await client.run("UPDATE `\(Self.database)`.people SET name = 'O''Neil\\\\x' WHERE id = 2")
            let content = ContentController(pageSize: { 1000 })
            await content.show(try await Self.people(client), in: Self.database, client: client, force: false)?.value
            content.filter.draft = FilterTree(RowFilter(column: "name", value: "O'Neil\\x"))
            await content.filter.apply()?.value
            #expect(content.load.error == nil)
            #expect(content.grid.rows.count == 1)
            #expect(content.unfilteredTotal == 3)
        }
    }

    @Test func structureAddsEditsAndDeletesAField() async throws {
        try await Self.withPeople { client in
            let structure = StructureController()
            await structure.show(try await Self.people(client), in: Self.database, client: client, force: false)?.value
            #expect(structure.load.error == nil)
            #expect(structure.columns.contains(.unsigned) && structure.columns.contains(.comment))

            structure.requestAddField()
            let sheet = try #require(structure.fieldSheet)
            #expect(!sheet.isSQLite && sheet.type == "int")
            sheet.name = "age"
            await structure.saveSheet()?.value
            #expect(sheet.error == nil)
            #expect(structure.names.contains("age"))

            let row = try #require(structure.names.firstIndex(of: "city"))
            let length = try #require(structure.columns.firstIndex(of: .length))
            await structure.edit(row: row, column: length, to: .text("80"))?.value
            #expect(structure.editError == nil)
            #expect(structure.definitions[row].length == "80")

            structure.selection = [try #require(structure.names.firstIndex(of: "age"))]
            structure.requestDeleteFields()
            await structure.confirmDeleteFields()?.value
            #expect(try await client.fields(of: "people", in: Self.database).map(\.name) == ["id", "name", "city", "score"])
        }
    }

    @Test func fieldSheetOffersMySQLsDefaultsAndExtras() async throws {
        try await Self.withPeople { client in
            let structure = StructureController()
            await structure.show(try await Self.people(client), in: Self.database, client: client, force: false)?.value
            let row: Int = try #require(structure.names.firstIndex(of: "score"))
            structure.requestEditField(row: row)
            let score = try #require(structure.fieldSheet)
            #expect(score.defaultKinds == [.none, .null, .value])
            #expect(score.extras.contains(.autoIncrement))
            score.type = "text"
            #expect(score.defaultKinds == [.none, .null])
        }
    }
}
