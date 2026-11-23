import AppKit
import QuarryKit
import SwiftUI

/// Settings > MCP (S-063): the MCP server's switch, port and Ask before
/// changes, adding Quarry to agents (S-066), the tokens (S-064), and the agents connected now.
struct MCPSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MCPHost.enabledKey) private var enabled = false
    @AppStorage(MCPHost.portKey) private var port = MCPHost.defaultPort
    @AppStorage(MCPHost.askKey) private var askBeforeChanges = true
    @State private var portText = ""
    @State private var deleting: AgentToken?
    @Environment(\.openWindow) private var openWindow
    private var host: MCPHost { MCPHost.shared }

    var body: some View {
        Section {
            Toggle("Enable MCP server", isOn: $enabled)
                .help("Let AI agents such as Claude Code use your saved connections through Quarry. Only apps on this Mac can connect.")
            LabeledContent("Status") {
                Label(host.statusText, systemImage: statusSymbol)
                    .foregroundStyle(statusStyle)
                    .accessibilityLabel("Status: \(host.statusText)")
            }
            LabeledContent("Port") {
                TextField("Port", text: $portText, prompt: Text(String(MCPHost.defaultPort)))
                    .labelsHidden()
                    .frame(width: Layout.portField)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commitPort)
                    .onAppear { portText = String(port) }
            }
            .help("The HTTP port on 127.0.0.1, from 1024 to 65535 (\(String(MCPHost.defaultPort)) by default). Press Return to use it.")
            Toggle("Ask before changes", isOn: $askBeforeChanges)
                .help("On: Quarry shows you each write_query and kill_process and runs it only when you click Allow.")
            LabeledContent {
                Button("Activity…") { openWindow(id: MCPActivityWindow.sceneID) }
            } label: {
                Text("Requests and agents")
                Text(model.agentActivity.isEmpty ? "None in the last 30 days"
                     : model.agentActivity.count == 1 ? "1 request in the last 30 days"
                     : "\(model.agentActivity.count.formatted()) requests in the last 30 days")
            }
            .help("Every request agents made in the last 30 days, and the agents connected now (⌥⇧⌘M)")
        } header: {
            Text("Server")
        } footer: {
            Text("Agents use a connection of their own, so your windows never change. Every statement they run shows in the Console (⇧⌘K).")
                .foregroundStyle(.secondary)
        }
        AgentClientList()
        @Bindable var host = host
        TokenList(draft: $host.tokenDraft, deleting: $deleting)
            .sheet(item: $host.tokenDraft) { draft in
                TokenSheet(draft: draft) { host.tokenDraft = nil }
            }
            .confirmationDialog("Delete the token “\(deleting?.name ?? "")”?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete", role: .destructive) {
                    if let deleting { model.deleteAgentToken(deleting) }
                    deleting = nil
                }
            } message: {
                Text("Agents using it are disconnected and can’t reconnect with it.")
            }
        if !host.clients.isEmpty {
            Section("Connected Agents") {
                ForEach(host.clients) { client in
                    LabeledContent {
                        Text("\(client.requests) request\(client.requests == 1 ? "" : "s") · \(client.lastActivity.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } label: {
                        Text(client.displayName)
                        Text(client.transport + " · " + host.tokenName(client))
                    }
                }
            }
        }
    }

    private var statusSymbol: String {
        switch host.status {
        case .running: "circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .off, .starting: "circle"
        }
    }

    private var statusStyle: AnyShapeStyle {
        switch host.status {
        case .running: AnyShapeStyle(.green)
        case .failed: AnyShapeStyle(.orange)
        case .off, .starting: AnyShapeStyle(.secondary)
        }
    }

    private func commitPort() {
        let number = Int(portText.trimmingCharacters(in: .whitespaces)) ?? -1
        if MCPHost.portRange.contains(number) { port = number } else { portText = String(port) }
    }
}

/// Settings > MCP > Tokens (S-064): the Automatic token first, then the HTTP tokens, each with its … menu.
private struct TokenList: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: TokenDraft?
    @Binding var deleting: AgentToken?

    var body: some View {
        Section {
            ForEach(model.agentTokens, id: \.uid) { token in
                LabeledContent {
                    HStack(spacing: Space.sm) {
                        Text(token.revoked ? "Revoked" : token.automatic ? "Stdio agents" : token.lastUsedText)
                            .foregroundStyle(.secondary)
                        menu(token)
                    }
                } label: {
                    Text(token.name)
                    Text(token.access.summary)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Spacer()
                Button("New Token…") { draft = TokenDraft(token: nil) }
                    .help("Make a token for an HTTP agent, with the access it needs")
            }
        } header: {
            Text("Tokens")
        } footer: {
            Text("Stdio agents (Quarry mcp) use the Automatic token. HTTP agents send their own token, shown once when you make it.")
                .foregroundStyle(.secondary)
        }
    }

    private func menu(_ token: AgentToken) -> some View {
        Menu {
            Button("Edit…") { draft = TokenDraft(token: token) }
            if !token.automatic {
                Button(token.revoked ? "Restore" : "Revoke") { model.setRevoked(token, !token.revoked) }
                Divider()
                Button("Delete…", role: .destructive) { deleting = token }
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Edit, revoke or delete \(token.name)")
    }
}
