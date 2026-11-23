import AppKit
import QuarryKit
import QuarryControllers

/// Self-test: Settings take effect without a relaunch (S-054). Every value it
/// changes is put back, since defaults are shared with the owner's own runs.
extension SelfTest {
    static func settings(session: Session) async {
        let defaults = UserDefaults.standard
        let keys = [Preferences.Key.nullText, Preferences.Key.monospaced, Preferences.Key.gridSize, Preferences.Key.gridLines,
                    Preferences.Key.editorSize, Preferences.Key.tabWidth, Preferences.Key.logStatements,
                    Preferences.Key.firstView, DatabaseClient.connectTimeoutKey]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for (key, value) in saved { defaults.set(value, forKey: key) }
        }
        guard let client = session.client else { return check("S-054 connected", false) }

        // Tables: the grid follows NULL text, font and grid lines as they change.
        guard let result = try? await client.run("SELECT NULL AS empty, 'text' AS word") else { return check("S-054 query", false) }
        let coordinator = DataGrid.Coordinator()
        let scroll = DataGrid.makeScrollView(coordinator: coordinator, accessibilityLabel: "Self-test")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.data = GridData(result)
        coordinator.rebuildColumns()
        coordinator.table?.reloadData()
        scroll.layoutSubtreeIfNeeded()
        func nullCell() -> String? {
            let column = coordinator.table?.column(withIdentifier: NSUserInterfaceItemIdentifier(coordinator.data.columns[0].id)) ?? 0
            return (coordinator.table?.view(atColumn: column, row: 0, makeIfNecessary: true) as? GridCellView)?.shownText
        }
        defaults.removeObject(forKey: Preferences.Key.nullText)
        check("S-054 the grid shows NULL by default", nullCell() == "NULL", nullCell() ?? "nil")
        defaults.set("(null)", forKey: Preferences.Key.nullText)
        try? await Task.sleep(for: .milliseconds(100))
        check("S-054 Show NULL as changes the grid at once", nullCell() == "(null)", nullCell() ?? "nil")

        let rowHeight = coordinator.table?.rowHeight ?? 0
        defaults.set(16, forKey: Preferences.Key.gridSize)
        defaults.set(false, forKey: Preferences.Key.gridLines)
        try? await Task.sleep(for: .milliseconds(100))
        check("S-054 Text size and Vertical grid lines change the open grid",
              (coordinator.table?.rowHeight ?? 0) > rowHeight && coordinator.table?.gridStyleMask == [],
              "\(rowHeight) → \(coordinator.table?.rowHeight ?? 0)")
        defaults.set(false, forKey: Preferences.Key.monospaced)
        check("S-054 Monospaced font off gives the system font", !DataStyle.gridNSFont.isFixedPitch)
        window.close()

        // Editor: the open query editor takes the new size and tab width.
        let editor = SQLEditor.Coordinator(SQLEditor(text: .constant("SELECT\t1"), cursor: .constant(0), selectRequest: .constant(nil)))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        editor.textView = text
        editor.followPreferences()
        defaults.set(13, forKey: Preferences.Key.editorSize)
        defaults.set(4, forKey: Preferences.Key.tabWidth)
        editor.applyPreferences()
        let tab4 = text.defaultParagraphStyle?.defaultTabInterval ?? 0
        defaults.set(18, forKey: Preferences.Key.editorSize)
        defaults.set(8, forKey: Preferences.Key.tabWidth)
        try? await Task.sleep(for: .milliseconds(100))
        check("S-054 Editor Text size and Tab width apply to the open editor",
              text.font?.pointSize == 18 && (text.defaultParagraphStyle?.defaultTabInterval ?? 0) > tab4 * 2,
              "\(text.font?.pointSize ?? 0) pt, tab \(tab4) → \(text.defaultParagraphStyle?.defaultTabInterval ?? 0)")

        // General: the Console stops logging statements, keeps errors.
        defaults.set(false, forKey: Preferences.Key.logStatements)
        try? await Task.sleep(for: .milliseconds(100))
        let before = ConsoleLog.shared.messages.count
        _ = try? await client.run("SELECT 'quarry_selftest_unlogged'")
        _ = try? await client.run("SELEC quarry_selftest_error")
        let added = ConsoleLog.shared.messages.dropFirst(before)
        check("S-054 Log statements off keeps only errors in the Console",
              added.count == 1 && added.first?.isError == true, "\(added.map(\.text))")
        defaults.set(true, forKey: Preferences.Key.logStatements)

        defaults.set(DetailView.structure.rawValue, forKey: Preferences.Key.firstView)
        check("S-054 New windows show: a new window starts on the chosen view", Session().view == .structure)

        // Network: the connect timeout gives up on a server that never answers.
        let silent = try? NWSilentServer()
        defaults.set(5, forKey: DatabaseClient.connectTimeoutKey)
        let start = ContinuousClock.now
        var message = ""
        do {
            _ = try await DatabaseClient.connect(ConnectionDetails(host: "127.0.0.1", port: String(silent?.port ?? 1),
                                                                   user: "quarry", password: "quarry"))
        } catch {
            message = DatabaseError.from(error).message
        }
        let waited = ContinuousClock.now - start
        check("S-054 Connection timeout stops waiting after its seconds",
              waited > .seconds(4) && waited < .seconds(8) && message.contains("5 seconds"), "\(waited) \(message)")
        silent?.stop()
    }
}

/// A TCP port that accepts connections and never says anything, like a
/// server that hangs before its handshake.
final class NWSilentServer {
    let port: Int
    private let socket: Int32

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        socket = fd
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func stop() { close(socket) }
}
