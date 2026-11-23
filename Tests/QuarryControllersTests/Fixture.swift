import Foundation
import Testing
import QuarryKit
import QuarryTestSupport

/// A fresh copy of tools/fixture-sqlite.sql per test, made with the system's
/// sqlite3 in the temporary folder, so tests can change it freely.
enum Fixture {
    static func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "quarry-controllers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "quarry_demo.sqlite")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "tools/fixture-sqlite.sql")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path]
        process.standardInput = try FileHandle(forReadingFrom: script)
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return url
    }

    /// The fixture file, opened.
    static func sqlite(readOnly: Bool = false) async throws -> DatabaseClient {
        let url = try file()
        return try await DatabaseClient.connect(ConnectionDetails(transport: .sqlite, file: url.path, readOnly: readOnly))
    }

    /// One object of `database`, by name.
    static func object(_ name: String, in database: String = "main", client: DatabaseClient) async throws -> DBObject {
        try #require(try await client.objects(in: database).first { $0.name == name })
    }

    /// One column of a query, as text.
    static func strings(_ sql: String, client: DatabaseClient) async throws -> [String?] {
        try await client.run(sql).rows.map { $0.first?.plainText }
    }
}
