import AppKit
import QuarryKit
import SwiftUI

/// Settings > MCP > Connect an Agent (S-066): a row per MCP client with Add, Remove or Update,
/// and Manual Setup… for any other client.
struct AgentClientList: View {
    @AppStorage(MCPHost.enabledKey) private var enabled = false
    @State private var states: [AgentClient: AgentSetupState] = [:]
    @State private var notes: [AgentClient: String] = [:]
    @State private var failure: (title: String, message: String)?
    let setup: AgentSetup

    init(setup: AgentSetup = AgentClientList.realSetup) {
        self.setup = setup
    }

    /// The owner's own home folder and this copy of Quarry.
    static var realSetup: AgentSetup {
        AgentSetup(home: FileManager.default.homeDirectoryForCurrentUser, bridge: MCPHost.bridgePath)
    }

    var body: some View {
        Section {
            ForEach(AgentClient.allCases) { client in
                row(client)
            }
            HStack {
                Spacer()
                Button("Manual Setup…") { MCPHost.shared.showingManualSetup = true }
                    .help("The command, JSON and HTTP endpoint for a client that isn't listed")
            }
        } header: {
            Text("Connect an Agent")
        } footer: {
            Text("Add writes Quarry into the client’s own settings and keeps the old file beside it as \(AgentSetup.backupSuffix).")
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .sheet(isPresented: Binding(get: { MCPHost.shared.showingManualSetup }, set: { MCPHost.shared.showingManualSetup = $0 })) {
            ManualSetupSheet()
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure?.message ?? "")
        }
    }

    private func row(_ client: AgentClient) -> some View {
        let state = states[client] ?? .notFound
        return LabeledContent {
            switch state {
            case .absent: action("Add", client, help: "Add Quarry to \(AgentSetup.displayPath(client))") { try setup.add(client) }
            case .added: action("Remove", client, help: "Take Quarry out of \(AgentSetup.displayPath(client))") { try setup.remove(client) }
            case .otherCopy(let path):
                action("Update", client, help: "It runs \(path). Update points it at this copy of Quarry in \(AgentSetup.displayPath(client)).") {
                    try setup.add(client)
                }
            case .notFound, .unreadable: EmptyView()
            }
        } label: {
            Text(client.name)
            Text(notes[client] ?? Self.summary(state, client))
        }
        .accessibilityElement(children: .combine)
    }

    static func summary(_ state: AgentSetupState, _ client: AgentClient) -> String {
        switch state {
        case .notFound: "Not found on this Mac"
        case .absent: "Not added"
        case .added: "Added"
        case .otherCopy: "Uses another copy of Quarry"
        case .unreadable: "Can’t read \(AgentSetup.displayPath(client)). Use Manual Setup…"
        }
    }

    private func action(_ title: String, _ client: AgentClient, help: String, _ run: @escaping () throws -> Void) -> some View {
        Button(title) {
            do {
                try run()
                if title == "Remove" {
                    notes[client] = nil
                } else {
                    // An agent reaches Quarry only while the server runs.
                    enabled = true
                    notes[client] = "Added. " + client.nextStep
                }
            } catch {
                let verb = title == "Remove" ? "remove Quarry from" : title == "Update" ? "update Quarry in" : "add Quarry to"
                failure = ("Couldn’t \(verb) \(client.name)", error.localizedDescription)
            }
            refresh()
        }
        .help(help)
    }

    private func refresh() {
        for client in AgentClient.allCases {
            states[client] = setup.state(client)
            if states[client] != .added { notes[client] = nil }
        }
    }
}

/// Manual Setup… (S-066): what any MCP client needs, each with Copy.
struct ManualSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?
    private var host: MCPHost { MCPHost.shared }

    static var json: String {
        let path = MCPHost.bridgePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "{\n  \"mcpServers\": {\n    \"quarry\": {\n      \"command\": \"\(path)\",\n      \"args\": [\"mcp\"]\n    }\n  }\n}"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Manual Setup").font(.headline)
            Form {
                Section {
                    entry("Command", MCPHost.bridgePath + " mcp", help: "What a stdio client runs. It opens Quarry when it isn't running and uses the Automatic token.")
                    entry("JSON", Self.json, help: "The mcpServers entry most clients read")
                    entry("Claude Code", MCPHost.claudeCommand, help: "A Terminal command that adds Quarry to Claude Code")
                } header: {
                    Text("Stdio")
                }
                Section {
                    entry("HTTP endpoint", host.endpoint, help: "For clients that connect over Streamable HTTP")
                } header: {
                    Text("HTTP")
                } footer: {
                    Text("HTTP clients send a token from Settings > MCP > Tokens as Authorization: Bearer <token>.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fitsContent(max: Layout.manualSetupMaxHeight)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.margin)
        .frame(width: Layout.manualSetupWidth)
        .noInitialFocus()
    }

    /// A row: the name and Copy on one line, the value below in full.
    private func entry(_ title: String, _ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(title)
                Spacer()
                Button(copied == title ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = title
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        if copied == title { copied = nil }
                    }
                }
                .accessibilityLabel("Copy \(title)")
            }
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(help)
    }
}
