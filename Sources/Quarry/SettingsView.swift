import QuarryKit
import QuarryControllers
import SwiftData
import SwiftUI

/// The Settings window (Command-Comma). One tab per topic, at most about
/// six. Each tab is a grouped Form that sizes to its content, so the
/// window grows to fit and shows no scroll bar it does not need. Every
/// setting applies at once (S-054).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .general: GeneralSettings()
            case .tables: TablesSettings()
            case .editor: EditorSettings()
            case .network: NetworkSettings()
            case .appearance: AppearanceSettings()
            case .mcp: MCPSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 520)
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, tables, editor, network, appearance, mcp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .tables: "Tables"
        case .editor: "Editor"
        case .network: "Network"
        case .appearance: "Appearance"
        case .mcp: "MCP"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .tables: "tablecells"
        case .editor: "chevron.left.forwardslash.chevron.right"
        case .network: "network"
        case .appearance: "paintpalette"
        case .mcp: "point.3.filled.connected.trianglepath.dotted"
        }
    }
}

/// Starting up, the first view, history and the Console.
struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \SavedConnection.name) private var connections: [SavedConnection]
    @AppStorage(Preferences.Key.connectOnLaunch) private var connectOnLaunch = false
    @AppStorage(Preferences.Key.firstView) private var firstView = DetailView.content.rawValue
    @AppStorage(Preferences.Key.logStatements) private var logStatements = true
    @AppStorage(AppModel.historyLimitKey) private var historyLimit = QueryHistory.defaultLimit

    var body: some View {
        Section("Starting Up") {
            Picker("Default connection", selection: defaultConnection) {
                Text("None").tag(UUID?.none)
                ForEach(connections) { connection in
                    Text(connection.displayName).tag(UUID?.some(connection.uid))
                }
            }
            .help("The saved connection a new window selects; also Connection > Default Connection")
            Toggle("Connect on launch", isOn: $connectOnLaunch)
                .disabled(defaultConnection.wrappedValue == nil)
                .help("When Quarry opens, its first window connects to the default connection")
            Picker("New windows show", selection: $firstView) {
                ForEach(Preferences.firstViews) { Text($0.title).tag($0.rawValue) }
            }
            .help("The view a new window or tab starts on. Choosing another table keeps the view you are in.")
        }
        Section("Query") {
            LabeledContent("Query history") {
                HStack(spacing: Space.xs) {
                    Text("Last \(historyLimit)").monospacedDigit()
                    Stepper("Query history", value: $historyLimit, in: QueryHistory.limitRange)
                        .labelsHidden()
                }
            }
            .help("How many past queries Query remembers for each server (1 to 100). Fewer takes effect at the next run.")
            Toggle("Log statements in the Console", isOn: $logStatements)
                .help("Off: the Console (⇧⌘K) records only errors")
        }
    }

    /// The default connection, through the same rule as Connection > Default Connection.
    private var defaultConnection: Binding<UUID?> {
        Binding(get: { connections.first(where: \.isDefault)?.uid },
                set: { uid in model.setDefaultConnection(uid) })
    }
}

/// How Content, Structure and query results show values.
struct TablesSettings: View {
    @AppStorage("content.pageSize") private var pageSize = LoadState.defaultPageSize
    @AppStorage(Preferences.Key.nullText) private var nullText = Preferences.defaultNullText
    @AppStorage(Preferences.Key.monospaced) private var monospaced = true
    @AppStorage(Preferences.Key.gridSize) private var gridSize = 12
    @AppStorage(Preferences.Key.gridLines) private var gridLines = true

    var body: some View {
        Section("Rows") {
            Picker("Rows per page", selection: $pageSize) {
                ForEach([100, 250, 500, 1000, 5000], id: \.self) { size in
                    Text(size.formatted()).tag(size)
                }
            }
            .help("How many rows Content loads at a time")
            TextField("Show NULL as", text: $nullText, prompt: Text(Preferences.defaultNullText))
                .help("The word the grid shows for NULL, in gray. Copy and Export keep their own NULL text.")
        }
        Section("Look") {
            Toggle("Monospaced font", isOn: $monospaced)
                .help("Off: the grid uses the system font, which fits more text in a column")
            Picker("Text size", selection: $gridSize) {
                ForEach(Preferences.gridSizes, id: \.self) { Text("\($0) pt").tag($0) }
            }
            .help("The grid's text size; rows grow with it")
            Toggle("Vertical grid lines", isOn: $gridLines)
                .help("Lines between columns")
        }
    }
}

/// The query editor's text and typing help.
struct EditorSettings: View {
    @AppStorage(Preferences.Key.editorSize) private var editorSize = 13
    @AppStorage(Preferences.Key.tabWidth) private var tabWidth = 4
    @AppStorage(SQLEditor.autoCompleteKey) private var autoComplete = true
    @AppStorage(SQLTextView.autoPairKey) private var autoPair = true
    @AppStorage(SQLTextView.autoUppercaseKey) private var autoUppercase = true

    var body: some View {
        Section("Text") {
            Picker("Text size", selection: $editorSize) {
                ForEach(Preferences.editorSizes, id: \.self) { Text("\($0) pt").tag($0) }
            }
            .help("The query editor’s text size, in SF Mono")
            Picker("Tab width", selection: $tabWidth) {
                ForEach(Preferences.tabWidths, id: \.self) { Text("\($0) spaces").tag($0) }
            }
            .help("How wide a tab looks; Shift Right (⌘]) inserts a tab")
        }
        Section("Typing") {
            Toggle("Suggest completions while typing", isOn: $autoComplete)
                .help("Show tables, columns and keywords as you type. Escape or ⌥⎋ shows them at any time.")
            Toggle("Insert closing brackets and quotes", isOn: $autoPair)
                .help("Typing ( ' \" or ` adds its match after the cursor, and wraps a selection")
            Toggle("Uppercase keywords as you type", isOn: $autoUppercase)
                .help("select becomes SELECT when you finish the word. Names such as status or date keep their case.")
        }
    }
}

/// Keep-alive pings (S-050) and the connect timeout (S-054), as in Sequel Pro's Network preferences.
struct NetworkSettings: View {
    @AppStorage(AppModel.keepAliveKey) private var keepAlive = true
    @AppStorage(AppModel.keepAliveIntervalKey) private var interval = AppModel.defaultKeepAliveInterval
    @AppStorage(DatabaseClient.connectTimeoutKey) private var timeout = DatabaseClient.defaultConnectTimeout

    var body: some View {
        Section {
            Picker("Connection timeout", selection: $timeout) {
                ForEach(Preferences.timeouts, id: \.self) { Text("\($0) seconds").tag($0) }
            }
            .help("How long Connect waits for the server to answer before it gives up")
            Toggle("Keep connections alive", isOn: $keepAlive)
                .help("Ping the server while a window is idle, so it does not close the connection")
            Picker("Ping every", selection: $interval) {
                ForEach([30, 60, 120, 300], id: \.self) { seconds in
                    Text(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))).tag(seconds)
                }
            }
            .disabled(!keepAlive)
            .help("How often an idle connection pings the server")
        } header: {
            Text("Connections")
        } footer: {
            Text("When a connection is lost anyway, Quarry offers to reconnect to the same database and table.")
                .foregroundStyle(.secondary)
        }
    }
}
