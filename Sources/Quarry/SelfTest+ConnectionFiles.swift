import AppKit
import QuarryKit

/// Self-test: connection and session files (S-055).
extension SelfTest {
    static func connectionFiles(session: Session) async {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quarry-selftest-files")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let spf = folder.appendingPathComponent("Local.spf")
        let sessionFile = folder.appendingPathComponent("Two.quarrysession")
        let savedQuery = session.query.text
        defer { session.query.text = savedQuery }

        session.database = "quarry_demo"
        await session.currentLoad?.value
        session.selectedObjectID = "table:orders"
        session.view = .structure
        await session.currentLoad?.value
        session.query.text = "SELECT 42 AS quarry_selftest_file"

        // ⌘S: passwords only with a file password, typed twice.
        session.requestSaveConnectionFile(asSession: false)
        guard let draft = session.connectionFileDraft else { return check("S-055 ⌘S opens Save Connection File", false) }
        draft.options = .init(connectsOnOpen: true, includesPasswords: true, includesQuery: true, includesPlace: true)
        check("S-055 Include passwords needs a file password", !draft.canSave)
        draft.password = "file secret"
        draft.confirmation = "file secrex"
        check("S-055 the two file passwords must match", !draft.canSave && draft.problem?.contains("match") == true)
        draft.confirmation = "file secret"
        do { try session.writeConnectionFile(to: spf) } catch { check("S-055 save", false, error.localizedDescription) }
        let data = (try? Data(contentsOf: spf)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        check("S-055 the saved file is encrypted: no host, database or password in it",
              session.connectionFileDraft == nil && ConnectionDocument.isEncrypted(data)
                  && !text.contains("quarry_demo") && !text.contains("127.0.0.1"), "\(data.count) bytes")

        // Open…: a wrong password keeps the sheet; the right one opens a connected tab where we were.
        session.openConnectionFile(spf)
        guard let unlock = session.fileUnlock else { return check("S-055 an encrypted file asks for its password", false) }
        unlock.password = "wrong"
        session.unlockConnectionFile()
        check("S-055 a wrong file password says so and keeps the sheet",
              session.fileUnlock === unlock && unlock.error?.contains("doesn’t open") == true, unlock.error ?? "")
        let before = Tabs.lastOpened
        unlock.password = "file secret"
        session.unlockConnectionFile()
        guard let tab = await openedTab(after: before) else { return check("S-055 the file opens in a new tab", false) }
        await tab.waitForConnect()
        for _ in 0..<100 where tab.selectedObjectID != "table:orders" { try? await Task.sleep(for: .milliseconds(20)) }
        check("S-055 the file connects with its password and returns to the database, table, view and query",
              tab.phase == .connected && tab.database == "quarry_demo" && tab.selectedObjectID == "table:orders"
                  && tab.view == .structure && tab.query.text == "SELECT 42 AS quarry_selftest_file",
              "\(tab.phase) \(tab.connectProblem?.message ?? "") \(tab.database ?? "") \(tab.selectedObjectID ?? "") \(tab.view)")

        // ⇧⌘S: both tabs, without passwords; then reopen them.
        tab.selectedObjectID = "table:customers"
        tab.view = .content
        await tab.currentLoad?.value
        session.requestSaveConnectionFile(asSession: true)
        guard let sessionDraft = session.connectionFileDraft else { return check("S-055 ⇧⌘S opens Save Session", false) }
        check("S-055 Save Session counts the connected tabs", sessionDraft.summary.hasPrefix("2 tabs"), sessionDraft.summary)
        sessionDraft.options = .init(connectsOnOpen: true, includesPasswords: false, includesQuery: false, includesPlace: true)
        try? session.writeConnectionFile(to: sessionFile)
        let saved = (try? Data(contentsOf: sessionFile)).flatMap { try? ConnectionDocument.decode($0) }
        check("S-055 the session file holds every tab, without passwords",
              saved?.tabs.count == 2 && saved?.tabs.allSatisfy { $0.details.password.isEmpty } == true
                  && Set(saved?.tabs.compactMap(\.table) ?? []) == ["orders", "customers"],
              "\(saved?.tabs.map { $0.table ?? "-" } ?? [])")
        closeTab(tab)
        try? await Task.sleep(for: .seconds(0.3))

        // Opening it from a connected window: both tabs come back beside it. With no
        // password saved they fill in the Connect page; give them the password to connect.
        guard var document = saved else { return }
        for window in document.windows.indices {
            for index in document.windows[window].indices { document.windows[window][index].details.password = "quarry" }
        }
        let start = Tabs.lastOpened
        await session.open(document).value
        _ = start
        func restoredTabs() -> [Session] { Tabs.connectedWindows().flatMap { $0 }.filter { $0 !== session } }
        for _ in 0..<250 where Set(restoredTabs().compactMap(\.selectedObjectID)) != ["table:orders", "table:customers"] {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let restored = Tabs.connectedWindows().flatMap { $0 }.filter { $0 !== session }
        check("S-055 opening a session file restores every tab",
              restored.count == 2 && Set(restored.compactMap(\.selectedObjectID)) == ["table:orders", "table:customers"]
                  && restored.contains { $0.view == .content },
              restored.map { "\($0.selectedObjectID ?? "-") \($0.view)" }.joined(separator: ", "))
        for tab in restored {
            tab.disconnect()
            tab.window?.close()
        }
        try? await Task.sleep(for: .seconds(0.3))
        session.window?.makeKeyAndOrderFront(nil)
        MenuState.shared.activate(session)
    }
}
