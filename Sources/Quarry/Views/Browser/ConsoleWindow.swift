import AppKit
import QuarryKit
import SwiftUI
import UniformTypeIdentifiers

/// The Console (S-039, ⇧⌘K): every statement Quarry sent from any window,
/// oldest first, with its time, connection and database. Errors show in red.
/// The toolbar filters, hides SELECT/SHOW and HELP statements, saves and clears.
struct ConsoleWindow: View {
    static let sceneID = "console"

    @State private var console = Console.shared
    @State private var selection: Set<ConsoleMessage.ID> = []
    @State private var search = ""
    @State private var columns = TableColumnCustomization<ConsoleMessage>()
    @AppStorage(Console.Key.showsTime) private var showsTime = true
    @AppStorage(Console.Key.showsConnection) private var showsConnection = true
    @AppStorage(Console.Key.showsDatabase) private var showsDatabase = true
    @AppStorage(Console.Key.showsSelectAndShow) private var showsSelectAndShow = true
    @AppStorage(Console.Key.showsHelp) private var showsHelp = true

    private var filter: ConsoleFilter {
        ConsoleFilter(text: search, showsSelectAndShow: showsSelectAndShow, showsHelp: showsHelp)
    }

    private var shown: [ConsoleMessage] { filter.apply(console.messages) }

    var body: some View {
        let shown = shown
        ScrollViewReader { proxy in
            table(shown)
                .onChange(of: console.messages.last?.id) {
                    // Follow new statements unless a row is selected.
                    guard selection.isEmpty, let last = shown.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                .onAppear { if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
        .overlay { emptyState(shown) }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter")
        .toolbar { toolbar(shown) }
        .navigationSubtitle(subtitle(shown))
        .frame(minWidth: Layout.consoleMinWidth, minHeight: Layout.consoleMinHeight)
        .noInitialFocus()
        .onAppear(perform: syncColumns)
        .onChange(of: columns) { readColumns() }
    }

    private func table(_ shown: [ConsoleMessage]) -> some View {
        Table(shown, selection: $selection, columnCustomization: $columns) {
            TableColumn("Time") { message in
                Text(message.date, format: Console.timeFormat)
                    .monospacedDigit()
                    .foregroundStyle(message.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            .width(Layout.consoleTimeWidth)
            .customizationID("time")
            TableColumn("Connection") { message in
                Text(message.connection)
                    .foregroundStyle(message.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            .width(min: Layout.consoleNameMin, ideal: Layout.consoleNameWidth, max: Layout.consoleNameMax)
            .customizationID("connection")
            TableColumn("Database") { message in
                Text(message.database ?? "")
                    .foregroundStyle(message.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            .width(min: Layout.consoleNameMin, ideal: Layout.consoleNameWidth, max: Layout.consoleNameMax)
            .customizationID("database")
            TableColumn("Query") { message in
                Text(message.text)
                    .font(DataStyle.gridFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(message.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .help(message.text)
            }
            .width(min: Layout.consoleQueryMin)
            .customizationID("query")
            .disabledCustomizationBehavior(.visibility)
        }
        .contextMenu(forSelectionType: ConsoleMessage.ID.self) { ids in
            Button("Copy") { copy(ids) }
                .disabled(ids.isEmpty)
        }
        .onCopyCommand {
            let text = copyText(selection)
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
        .accessibilityLabel("Console")
    }

    @ViewBuilder
    private func emptyState(_ shown: [ConsoleMessage]) -> some View {
        if console.messages.isEmpty {
            ContentUnavailableView("No Statements", systemImage: "terminal",
                                   description: Text("Statements Quarry sends to a server show here as they run."))
        } else if shown.isEmpty {
            ContentUnavailableView.search(text: search)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ shown: [ConsoleMessage]) -> some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Toggle("Show Time Stamps", isOn: $showsTime)
                Toggle("Show Connections", isOn: $showsConnection)
                Toggle("Show Databases", isOn: $showsDatabase)
                Divider()
                Toggle("Show SELECT/SHOW Statements", isOn: $showsSelectAndShow)
                Toggle("Show HELP Statements", isOn: $showsHelp)
            } label: {
                Label("View Options", systemImage: "line.3.horizontal.decrease")
            }
            .help("Choose the columns, and whether SELECT, SHOW and HELP statements show")
            .onChange(of: [showsTime, showsConnection, showsDatabase]) { syncColumns() }
            Button {
                save(shown)
            } label: {
                Label(filter.isEmpty ? "Save As…" : "Save View As…", systemImage: "square.and.arrow.down")
            }
            .help(filter.isEmpty ? "Save the console as a .sql file" : "Save the statements shown as a .sql file")
            .disabled(shown.isEmpty)
            Button {
                console.clear()
                selection = []
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .help("Remove every statement from the console (⌥⌘K)")
            .disabled(console.messages.isEmpty)
        }
    }

    private func subtitle(_ shown: [ConsoleMessage]) -> String {
        let total = console.messages.count
        if shown.count == total {
            let statements = shown.count { !$0.isError }
            return statements == 1 ? "1 statement" : "\(statements) statements"
        }
        return "\(shown.count) of \(total) shown"
    }

    // MARK: Columns

    /// The gear menu's toggles decide which columns show.
    private func syncColumns() {
        columns[visibility: "time"] = showsTime ? .visible : .hidden
        columns[visibility: "connection"] = showsConnection ? .visible : .hidden
        columns[visibility: "database"] = showsDatabase ? .visible : .hidden
    }

    /// The header's menu hides columns too; the gear menu follows it.
    private func readColumns() {
        let time = columns[visibility: "time"] != .hidden
        let connection = columns[visibility: "connection"] != .hidden
        let database = columns[visibility: "database"] != .hidden
        if time != showsTime { showsTime = time }
        if connection != showsConnection { showsConnection = connection }
        if database != showsDatabase { showsDatabase = database }
    }

    private var shownColumns: ConsoleText.Columns {
        .init(time: showsTime, connection: showsConnection, database: showsDatabase)
    }

    // MARK: Copy and save

    private func copyText(_ ids: Set<ConsoleMessage.ID>) -> String {
        let messages = shown.filter { ids.contains($0.id) }
        return ConsoleText.text(messages, columns: shownColumns) { $0.formatted(Console.timeFormat) }
    }

    private func copy(_ ids: Set<ConsoleMessage.ID>) {
        let text = copyText(ids)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save(_ shown: [ConsoleMessage]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = "Console.sql"
        let columns = shownColumns
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ConsoleText.text(shown, columns: columns) { $0.formatted(Console.timeFormat) }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
