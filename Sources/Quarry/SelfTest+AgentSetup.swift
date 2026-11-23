import Foundation
import QuarryKit

/// Self-test: one-click agent setup (S-066), on copies of each client's config in a temporary home folder,
/// never the owner's real ones.
extension SelfTest {
    static func agentSetup() {
        let fm = FileManager.default
        let home = URL(filePath: Store.url.path + ".agent-home")
        try? fm.removeItem(at: home)
        let setup = AgentSetup(home: home, bridge: MCPHost.bridgePath)
        let real = AgentClientList.realSetup
        check("S-066 the self-test edits a temporary home, not the owner's",
              setup.home.path.hasPrefix("/tmp/") || setup.home.path.hasPrefix("/private/tmp/"), setup.home.path)
        guard setup.home != real.home else { return }

        // Claude Code, Codex and Cursor are "installed"; Claude Desktop is not.
        let claude = #"{"numStartups":3,"mcpServers":{"other":{"command":"node","args":["a.js"]}},"projects":{"/x":{"allowedTools":[]}}}"#
        let codex = "model = \"gpt-5\"\n\n[mcp_servers.other]\ncommand = \"php\"\nargs = [\"artisan\"]\n"
        try? fm.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: home.appending(path: ".cursor"), withIntermediateDirectories: true)
        try? Data(claude.utf8).write(to: setup.url(.claudeCode))
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: setup.url(.claudeCode).path)
        try? Data(codex.utf8).write(to: setup.url(.codex))
        let before = AgentClient.allCases.map { setup.state($0) }
        check("S-066 Connect an Agent offers Add for each client found and none for a client that isn't here",
              before == [.absent, .absent, .absent, .notFound]
                  && AgentClientList.summary(.notFound, .claudeDesktop) == "Not found on this Mac",
              "\(before)")

        for client in [AgentClient.claudeCode, .codex, .cursor] { try? setup.add(client) }
        let after = AgentClient.allCases.map { setup.state($0) }
        let claudeText = String(decoding: fm.contents(atPath: setup.url(.claudeCode).path) ?? Data(), as: UTF8.self)
        let codexText = (try? String(contentsOf: setup.url(.codex), encoding: .utf8)) ?? ""
        let cursorCommand = try? AgentConfigEdit.jsonCommand(fm.contents(atPath: setup.url(.cursor).path) ?? Data())
        let mode = (try? fm.attributesOfItem(atPath: setup.url(.claudeCode).path))?[.posixPermissions] as? Int
        check("S-066 Add writes the bridge command and keeps the rest of the file and its permissions",
              after == [.added, .added, .added, .notFound] && cursorCommand == MCPHost.bridgePath
                  && claudeText.contains("\"other\"") && claudeText.contains("\"numStartups\" : 3") && claudeText.contains("allowedTools")
                  && codexText.hasPrefix(codex) && codexText.contains("[mcp_servers.quarry]") && mode == 0o600,
              "\(after) mode \(mode.map { String($0, radix: 8) } ?? "none")")
        check("S-066 a backup of the old file is made first",
              fm.contents(atPath: setup.url(.claudeCode).path + AgentSetup.backupSuffix) == Data(claude.utf8)
                  && fm.contents(atPath: setup.url(.codex).path + AgentSetup.backupSuffix) == Data(codex.utf8))

        // Another copy of Quarry: Update points it here.
        let elsewhere = AgentSetup(home: home, bridge: "/Applications/Old/Quarry.app/Contents/MacOS/Quarry")
        try? elsewhere.add(.cursor)
        let other = setup.state(.cursor)
        try? setup.add(.cursor)
        check("S-066 a command for another copy of Quarry shows Update, and Update points it at this one",
              other == .otherCopy("/Applications/Old/Quarry.app/Contents/MacOS/Quarry") && setup.state(.cursor) == .added,
              "\(other)")

        for client in [AgentClient.claudeCode, .codex, .cursor] { try? setup.remove(client) }
        let removedClaude = String(decoding: fm.contents(atPath: setup.url(.claudeCode).path) ?? Data(), as: UTF8.self)
        let removedCodex = (try? String(contentsOf: setup.url(.codex), encoding: .utf8)) ?? ""
        check("S-066 Remove takes out only Quarry",
              AgentClient.allCases.prefix(3).allSatisfy { setup.state($0) == .absent }
                  && removedClaude.contains("\"other\"") && removedCodex.trimmingCharacters(in: .newlines) == codex.trimmingCharacters(in: .newlines))

        try? Data("{ not json".utf8).write(to: setup.url(.cursor))
        var refused = false
        do { try setup.add(.cursor) } catch { refused = true }
        check("S-066 a file that isn't valid is left alone",
              setup.state(.cursor) == .unreadable && refused
                  && fm.contents(atPath: setup.url(.cursor).path) == Data("{ not json".utf8))
        check("S-066 Manual Setup shows the command and a JSON entry",
              ManualSetupSheet.json.contains("\"command\": \"\(MCPHost.bridgePath)\"") && ManualSetupSheet.json.contains("\"args\": [\"mcp\"]"))
        try? fm.removeItem(at: home)
    }
}
