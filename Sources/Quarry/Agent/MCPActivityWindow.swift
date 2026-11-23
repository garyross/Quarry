import AppKit
import QuarryKit
import SwiftUI
import UniformTypeIdentifiers

/// What MCP Activity shows (S-065), shared so the self-test and snapshots can set it.
@MainActor @Observable
final class MCPActivityState {
    static let shared = MCPActivityState()

    enum Page: String, CaseIterable, Identifiable {
        case requests = "Requests", clients = "Clients"
        var id: String { rawValue }
    }

    var page: Page = .requests
    var search = ""
    var range: ActivityRange = .all
    /// A token's name, or nil for every token.
    var token: String?

    var filter: ActivityFilter { ActivityFilter(text: search, range: range, token: token) }
}

/// Window > MCP Activity (⌥⇧⌘M, S-065): every request agents made, kept 30
/// days, and the agents connected now, with Disconnect.
struct MCPActivityWindow: View {
    static let sceneID = "mcp-activity"

    @Environment(AppModel.self) private var model
    @State private var state = MCPActivityState.shared
    @State private var selection: Set<ActivityRecord.ID> = []
    @State private var clientSelection: Set<MCPClient.ID> = []
    @State private var confirmingClear = false
    private var host: MCPHost { MCPHost.shared }

    var body: some View {
        let shown = state.filter.apply(model.agentActivity)
        Group {
            switch state.page {
            case .requests: requests(shown)
            case .clients: clients
            }
        }
        .searchable(text: $state.search, placement: .toolbar, prompt: "Filter")
        .toolbar { toolbar(shown) }
        .navigationSubtitle(subtitle(shown))
        .frame(minWidth: Layout.activityMinWidth, minHeight: Layout.activityMinHeight)
        .noInitialFocus()
        .confirmationDialog("Clear all MCP activity?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { model.clearAgentActivity(before: nil) }
        } message: {
            Text("Quarry forgets every request agents made. This can’t be undone.")
        }
    }

    // MARK: Requests

    private func requests(_ shown: [ActivityRecord]) -> some View {
        Table(shown, selection: $selection) {
            TableColumn("Time") { record in
                Text(record.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(record.date.formatted(date: .complete, time: .standard))
            }
            .width(min: Layout.consoleNameMin, ideal: Layout.activityTimeWidth)
            TableColumn("Client") { Text($0.client) }
                .width(min: Layout.consoleNameMin, ideal: Layout.activityNameWidth)
            TableColumn("Token") { Text($0.token).foregroundStyle(.secondary) }
                .width(min: Layout.consoleNameMin, ideal: Layout.activityTokenWidth)
            TableColumn("Connection") { record in
                Text(record.database.isEmpty ? record.connection : record.connection + " · " + record.database)
                    .foregroundStyle(.secondary)
                    .help(record.database.isEmpty ? record.connection : record.connection + " · " + record.database)
            }
            .width(min: Layout.consoleNameMin, ideal: Layout.activityPlaceWidth)
            TableColumn("Tool") { Text($0.tool).font(DataStyle.gridFont) }
                .width(min: Layout.consoleNameMin, ideal: Layout.activityNameWidth)
            TableColumn("Statement") { record in
                Text(record.statement)
                    .font(DataStyle.gridFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(record.statement)
            }
            .width(min: Layout.activityStatementMin)
            TableColumn("Status") { record in
                Text(record.status.title)
                    .foregroundStyle(record.status == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .help(record.message.isEmpty ? "It worked." : record.message)
            }
            .width(Layout.activityShortWidth)
            TableColumn("Duration") { record in
                Text(record.durationText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(Layout.activityShortWidth)
        }
        .contextMenu(forSelectionType: ActivityRecord.ID.self) { ids in
            Button("Copy Statement") { copy(shown.filter { ids.contains($0.id) }.map(\.statement).joined(separator: "\n")) }
                .disabled(ids.isEmpty)
        }
        .onCopyCommand {
            let text = shown.filter { selection.contains($0.id) }.map(\.statement).joined(separator: "\n")
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
        .overlay {
            if model.agentActivity.isEmpty {
                ContentUnavailableView("No Activity", systemImage: "list.bullet.rectangle",
                                       description: Text("Requests agents make through the MCP server show here."))
            } else if shown.isEmpty {
                ContentUnavailableView("No Matching Requests", systemImage: "magnifyingglass",
                                       description: Text("Try other words, a longer time range, or All Tokens."))
            }
        }
        .accessibilityLabel("Requests")
    }

    // MARK: Clients

    private var clients: some View {
        let list = host.clients.filter { client in
            let words = state.search.lowercased().split(whereSeparator: \.isWhitespace)
            let text = [client.displayName, host.tokenName(client), client.transport].joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) } && (state.token == nil || host.tokenName(client) == state.token)
        }
        return Table(list, selection: $clientSelection) {
            TableColumn("Client") { Text($0.displayName) }
                .width(min: Layout.activityNameWidth, ideal: Layout.activityTimeWidth + Layout.activityNameWidth)
            TableColumn("Token") { Text(host.tokenName($0)).foregroundStyle(.secondary) }
                .width(min: Layout.consoleNameMin, ideal: Layout.activityNameWidth)
            TableColumn("Transport") { Text($0.transport).foregroundStyle(.secondary) }
                .width(Layout.activityShortWidth)
            TableColumn("First Request") { client in
                Text(client.started, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
            }
            TableColumn("Last Request") { client in
                Text(client.lastActivity.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
            }
            TableColumn("Requests") { client in
                Text(client.requests.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(Layout.activityShortWidth)
        }
        .contextMenu(forSelectionType: MCPClient.ID.self) { ids in
            Button("Disconnect") { disconnect(ids) }
                .disabled(ids.isEmpty)
        }
        .onDeleteCommand { disconnect(clientSelection) }
        .overlay {
            if host.clients.isEmpty {
                ContentUnavailableView("No Agents Connected", systemImage: "network.slash",
                                       description: Text("MCP server: " + host.statusText))
            } else if list.isEmpty {
                ContentUnavailableView.search(text: state.search)
            }
        }
        .accessibilityLabel("Clients")
    }

    private func disconnect(_ ids: Set<MCPClient.ID>) {
        let chosen = host.clients.filter { ids.contains($0.id) }
        clientSelection.subtract(ids)
        Task { for client in chosen { await host.disconnect(client: client) } }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ shown: [ActivityRecord]) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $state.page) {
                ForEach(MCPActivityState.Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Requests agents made, or the agents connected now")
        }
        ToolbarItemGroup {
            Menu {
                Picker("Time Range", selection: $state.range) {
                    ForEach(ActivityRange.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Token", selection: $state.token) {
                    Text("All Tokens").tag(String?.none)
                    ForEach(model.agentTokens, id: \.uid) { Text($0.name).tag(Optional($0.name)) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Show", systemImage: "line.3.horizontal.decrease")
            }
            .help("Choose the time range and the token to show")
            if state.page == .requests {
                Button {
                    export(shown)
                } label: {
                    Label("Export CSV…", systemImage: "square.and.arrow.up")
                }
                .help("Save the requests shown as a CSV file")
                .disabled(shown.isEmpty)
                Menu {
                    Button("Older Than 24 Hours") { model.clearAgentActivity(before: .now.addingTimeInterval(-86_400)) }
                    Button("Older Than 7 Days") { model.clearAgentActivity(before: .now.addingTimeInterval(-7 * 86_400)) }
                    Divider()
                    Button("All…") { confirmingClear = true }
                } label: {
                    Label("Clear Activity", systemImage: "trash")
                }
                .help("Forget older requests. Quarry keeps them 30 days.")
                .disabled(model.agentActivity.isEmpty)
            } else {
                Button {
                    disconnect(clientSelection)
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .help("End this agent’s session and stop its running query. It can connect again.")
                .disabled(clientSelection.isEmpty)
            }
        }
    }

    private func subtitle(_ shown: [ActivityRecord]) -> String {
        switch state.page {
        case .requests:
            let total = model.agentActivity.count
            if shown.count == total { return total == 1 ? "1 request" : "\(total.formatted()) requests" }
            return "\(shown.count.formatted()) of \(total.formatted()) shown"
        case .clients:
            let count = host.clients.count
            return count == 1 ? "1 agent connected" : "\(count) agents connected"
        }
    }

    // MARK: Copy and export

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(_ shown: [ActivityRecord]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "MCP Activity.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AgentActivity.csv(shown).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
