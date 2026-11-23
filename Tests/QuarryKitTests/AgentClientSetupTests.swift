import Foundation
import Testing
@testable import QuarryKit

/// S-066: adding Quarry to a client's config keeps everything else.
struct AgentClientSetupTests {
    let bridge = "/Users/me/Applications/Quarry.app/Contents/MacOS/Quarry"

    @Test func jsonAddUpdateRemoveKeepsOtherServers() throws {
        let original = Data(#"{"theme":"dark","mcpServers":{"other":{"command":"node","args":["x.js"]}},"numStartups":12,"flag":true}"#.utf8)
        #expect(try AgentConfigEdit.jsonCommand(original) == nil)
        let added = try AgentConfigEdit.jsonAdding(original, entry: AgentConfigEdit.entry(for: .cursor, bridge: bridge))
        #expect(try AgentConfigEdit.jsonCommand(added) == bridge)
        let root = try #require(JSONSerialization.jsonObject(with: added) as? [String: Any])
        #expect(root["theme"] as? String == "dark")
        #expect(root["numStartups"] as? Int == 12)
        #expect(root["flag"] as? Bool == true)
        #expect(((root["mcpServers"] as? [String: Any])?["other"] as? [String: Any])?["command"] as? String == "node")
        #expect(!String(decoding: added, as: UTF8.self).contains(#"\/"#))

        let other = try AgentConfigEdit.jsonAdding(original, entry: AgentConfigEdit.entry(for: .cursor, bridge: "/Applications/Quarry.app/Contents/MacOS/Quarry"))
        let updated = try AgentConfigEdit.jsonAdding(other, entry: AgentConfigEdit.entry(for: .cursor, bridge: bridge))
        #expect(try AgentConfigEdit.jsonCommand(updated) == bridge)

        let removed = try AgentConfigEdit.jsonRemoving(added)
        #expect(try AgentConfigEdit.jsonCommand(removed) == nil)
        let servers = try #require((JSONSerialization.jsonObject(with: removed) as? [String: Any])?["mcpServers"] as? [String: Any])
        #expect(servers.keys.sorted() == ["other"])
    }

    @Test func jsonEmptyFileAndClaudeCodeEntry() throws {
        let added = try AgentConfigEdit.jsonAdding(Data(), entry: AgentConfigEdit.entry(for: .claudeCode, bridge: bridge))
        let entry = try #require(((JSONSerialization.jsonObject(with: added) as? [String: Any])?["mcpServers"] as? [String: Any])?["quarry"] as? [String: Any])
        #expect(entry["type"] as? String == "stdio")
        #expect(entry["args"] as? [String] == ["mcp"])
        #expect(throws: (any Error).self) { try AgentConfigEdit.jsonCommand(Data("{ not json".utf8)) }
        #expect(throws: (any Error).self) { try AgentConfigEdit.jsonCommand(Data("[1, 2]".utf8)) }
    }

    @Test func tomlKeepsOtherTablesAndSubtables() {
        let original = """
        model = "gpt-5"

        [projects."/Users/me/x"]
        trust_level = "trusted"

        [mcp_servers.other]
        command = "php"
        args = ["artisan"]

        """
        #expect(AgentConfigEdit.tomlCommand(original) == nil)
        let added = AgentConfigEdit.tomlAdding(original, bridge: bridge)
        #expect(AgentConfigEdit.tomlCommand(added) == bridge)
        #expect(added.hasPrefix(original))
        #expect(added.hasSuffix("[mcp_servers.quarry]\ncommand = \"\(bridge)\"\nargs = [\"mcp\"]\n"))
        #expect(AgentConfigEdit.tomlRemoving(added).trimmingCharacters(in: .newlines) == original.trimmingCharacters(in: .newlines))

        let withOld = original + """
        [mcp_servers.quarry]
        command = "/Applications/Quarry.app/Contents/MacOS/Quarry"
        args = ["mcp"]

        [mcp_servers.quarry.env]
        A = "1"

        [mcp_servers.zeta]
        command = "z"
        """
        #expect(AgentConfigEdit.tomlCommand(withOld) == "/Applications/Quarry.app/Contents/MacOS/Quarry")
        let updated = AgentConfigEdit.tomlAdding(withOld, bridge: bridge)
        #expect(AgentConfigEdit.tomlCommand(updated) == bridge)
        #expect(!updated.contains("[mcp_servers.quarry.env]"))
        #expect(updated.contains("[mcp_servers.zeta]\ncommand = \"z\""))
        #expect(updated.components(separatedBy: "[mcp_servers.quarry]").count == 2)
        let removed = AgentConfigEdit.tomlRemoving(withOld)
        #expect(!removed.contains("quarry"))
        #expect(removed.contains("[mcp_servers.other]") && removed.contains("[mcp_servers.zeta]"))
    }

    @Test func tomlQuotesPathsAndReadsQuotedNames() {
        let added = AgentConfigEdit.tomlAdding("", bridge: #"/Apps/My "Q"\Quarry"#)
        #expect(AgentConfigEdit.tomlCommand(added) == #"/Apps/My "Q"\Quarry"#)
        #expect(AgentConfigEdit.tomlCommand("[mcp_servers.\"quarry\"]\ncommand = 'x'\n") == "x")
    }

    @Test func setupStatesBackupsAndPermissions() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "quarry-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: ".cursor"), withIntermediateDirectories: true)
        let setup = AgentSetup(home: home, bridge: bridge)
        #expect(setup.state(.claudeDesktop) == .notFound)
        #expect(setup.state(.cursor) == .absent)
        #expect(throws: AgentSetupError.notFound("Codex")) { try setup.add(.codex) }

        try setup.add(.cursor)
        #expect(setup.state(.cursor) == .added)
        #expect(!FileManager.default.fileExists(atPath: setup.url(.cursor).path + AgentSetup.backupSuffix))

        let claude = setup.url(.claudeCode)
        try Data(#"{"userID":"abc"}"#.utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claude.path)
        try setup.add(.claudeCode)
        #expect(setup.state(.claudeCode) == .added)
        #expect(FileManager.default.contents(atPath: claude.path + AgentSetup.backupSuffix) == Data(#"{"userID":"abc"}"#.utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: claude.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try setup.remove(.claudeCode)
        #expect(setup.state(.claudeCode) == .absent)

        try Data("{ broken".utf8).write(to: setup.url(.cursor))
        #expect(setup.state(.cursor) == .unreadable)
        #expect(throws: AgentSetupError.unreadable("~/.cursor/mcp.json")) { try setup.add(.cursor) }
        #expect(FileManager.default.contents(atPath: setup.url(.cursor).path) == Data("{ broken".utf8))
    }
}
