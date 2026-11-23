import AppKit
import QuarryKit
import SwiftUI
import UniformTypeIdentifiers

/// Server Processes (⌥⌘P, S-053): every connection to the server and what it
/// runs, refreshed every few seconds on the list's own connection. Kill Query
/// and Kill Connection act on one selected row and always ask first.
struct ProcessListWindow: View {
    static let sceneID = "processes"

    let listID: UUID?

    var body: some View {
        if let listID, let list = ProcessList.open[listID] {
            ProcessListView(list: list)
                .onDisappear { list.stop() }
        } else {
            ContentUnavailableView("Connection Closed", systemImage: "bolt.horizontal.circle",
                                   description: Text("Open Database > Show Server Processes… (⌥⌘P) from a connected window."))
                .frame(minWidth: Layout.processesMinWidth, minHeight: Layout.processesMinHeight)
        }
    }
}

struct ProcessListView: View {
    @Bindable var list: ProcessList
    @State private var columns = TableColumnCustomization<ServerProcess>()

    var body: some View {
        table
            .overlay { emptyState }
            .searchable(text: $list.search, placement: .toolbar, prompt: "Filter")
            .toolbar { toolbar }
            .navigationTitle("Server Processes")
            .navigationSubtitle("\(list.server) · \(list.countText)")
            .frame(minWidth: Layout.processesMinWidth, minHeight: Layout.processesMinHeight)
            .noInitialFocus()
            .task { await list.start() }
            .alert(list.killTitle, isPresented: Binding(get: { list.pendingKill != nil },
                                                        set: { if !$0 { list.pendingKill = nil } })) {
                Button("Kill", role: .destructive) { list.confirmKill() }
                Button("Cancel", role: .cancel) { list.pendingKill = nil }
            } message: {
                Text(list.killMessage)
            }
            .alert("Couldn’t Kill", isPresented: Binding(get: { list.killError != nil },
                                                         set: { if !$0 { list.killError = nil } })) {
                Button("OK") { list.killError = nil }
            } message: {
                Text(list.killError?.message ?? "")
            }
    }

    private var table: some View {
        Table(list.shown, selection: $list.selection, columnCustomization: $columns) {
            TableColumn("ID") { process in
                Text(String(process.id))
                    .monospacedDigit()
                    .foregroundStyle(process.id == list.ownConnectionID ? .secondary : .primary)
                    .help(help(process))
            }
            .width(Layout.processesIDWidth)
            .customizationID("id")
            TableColumn("User") { Text($0.user).lineLimit(1) }
                .width(min: Layout.processesNameMin, ideal: Layout.processesNameWidth)
                .customizationID("user")
            TableColumn("Host") { Text($0.host).lineLimit(1) }
                .width(min: Layout.processesNameMin, ideal: Layout.processesNameWidth)
                .customizationID("host")
            TableColumn("Database") { Text($0.database ?? "").lineLimit(1) }
                .width(min: Layout.processesNameMin, ideal: Layout.processesNameWidth)
                .customizationID("database")
            TableColumn("Command") { Text($0.command).lineLimit(1) }
                .width(min: Layout.processesNameMin, ideal: Layout.processesCommandWidth)
                .customizationID("command")
            TableColumn("Time") { process in
                Text(process.time.formatted())
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(Layout.processesTimeWidth)
            .customizationID("time")
            TableColumn("State") { Text($0.state).lineLimit(1) }
                .width(min: Layout.processesNameMin, ideal: Layout.processesNameWidth)
                .customizationID("state")
            TableColumn("Info") { process in
                Text(process.info ?? "")
                    .font(DataStyle.gridFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(process.info ?? "")
            }
            .width(min: Layout.processesInfoMin)
            .customizationID("info")
            .disabledCustomizationBehavior(.visibility)
        }
        .contextMenu(forSelectionType: ServerProcess.ID.self) { ids in
            Button("Copy") { list.copy(ids) }
                .disabled(ids.isEmpty)
            Divider()
            Button("Kill Query…") { list.requestKill(connection: false, ids) }
                .disabled(!list.canKill(connection: false, ids))
            Button("Kill Connection…") { list.requestKill(connection: true, ids) }
                .disabled(!list.canKill(connection: true, ids))
        }
        .onCopyCommand {
            let rows = list.selected()
            return rows.isEmpty ? [] : [NSItemProvider(object: ServerProcess.text(rows) as NSString)]
        }
        .onDeleteCommand { list.requestKill(connection: false) }
        .accessibilityLabel("Server processes")
    }

    private func help(_ process: ServerProcess) -> String {
        if process.id == list.ownConnectionID { return "This list’s own connection" }
        if process.id == list.windowConnectionID { return "The connection of the window you opened this from" }
        return "Connection \(process.id)"
    }

    @ViewBuilder private var emptyState: some View {
        if list.isClosed {
            ContentUnavailableView("Connection Closed", systemImage: "bolt.horizontal.circle",
                                   description: Text("The window this list came from disconnected."))
        } else if let error = list.error, list.processes.isEmpty {
            ContentUnavailableView {
                Label("Can’t Read Processes", systemImage: StatusStyle.errorSymbol)
            } description: {
                Text(error.message).textSelection(.enabled)
            }
        } else if list.processes.isEmpty, list.isLoading {
            ProgressView().controlSize(.small).accessibilityLabel("Loading processes")
        } else if list.shown.isEmpty, !list.processes.isEmpty {
            ContentUnavailableView.search(text: list.search)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await list.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help(list.autoRefresh ? "Refresh now; the list also refreshes every \(list.interval) s"
                                   : "Read the process list again")
            .disabled(list.isClosed)
            Menu {
                Toggle("Auto Refresh", isOn: $list.autoRefresh)
                Picker("Auto Refresh Interval", selection: $list.interval) {
                    ForEach(ProcessList.intervals, id: \.self) { Text("Every \($0) Seconds").tag($0) }
                }
                Divider()
                Toggle("Show Full Process List", isOn: $list.full)
            } label: {
                Label("View Options", systemImage: "line.3.horizontal.decrease")
            }
            .help("Auto refresh and its interval, and whether Info shows each statement in full")
        }
        ToolbarItemGroup {
            Button {
                list.requestKill(connection: false)
            } label: {
                Label("Kill Query", systemImage: "stop.circle")
            }
            .help("Stop the selected connection’s statement and keep the connection (Delete)")
            .disabled(!list.canKill(connection: false))
            Button {
                list.requestKill(connection: true)
            } label: {
                Label("Kill Connection", systemImage: "xmark.circle")
            }
            .help("Close the selected connection")
            .disabled(!list.canKill(connection: true))
            Button(action: save) {
                Label("Save As…", systemImage: "square.and.arrow.down")
            }
            .help("Save the processes shown to a text file")
            .disabled(list.shown.isEmpty)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "ServerProcesses.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try list.save(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
