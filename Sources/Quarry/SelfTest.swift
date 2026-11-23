import AppKit
import QuarryKit
import SwiftData

/// Self-test for agents: runs the app's real functions against the private
/// test server (tools/testdb.sh), prints PASS or FAIL per check, and quits
/// with exit code 0 or 1.
///   tools/selftest.sh
/// Each check names the story it proves.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0
    /// Keeps App Nap from slowing timers while the self-test runs behind other
    /// windows: the stall checks measure the app, not the OS throttling it.
    private static var activity: NSObjectProtocol?

    /// Only the first window runs it; tabs the test opens must not start it again.
    private static var started = false

    static func runIfRequested(model: AppModel, session: Session) {
        guard requested, !started else { return }
        started = true
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Self-test timing checks")
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            await organizingConnections(model: model, session: session)
            await connecting(model: model, session: session)
            await sshTunnel(model: model, session: session)
            await ssl(model: model, session: session)
            await browsing(session: session)
            await editing(session: session)
            await fieldEditing(session: session)
            await bitEditor(session: session)
            await rows(session: session)
            await filtering(session: session)
            await savedFilters(model: model, session: session)
            await foreignKeyLinks(session: session)
            await visitHistory(session: session)
            await tabs(session: session)
            await favorites(model: model, session: session)
            await databaseTools(session: session)
            await goToDatabase(session: session)
            await newDatabase(session: session)
            await newTable(session: session)
            await tableActions(model: model, session: session)
            await fieldChanges(session: session)
            await indexChanges(session: session)
            await foreignKeyChanges(session: session)
            await triggerChanges(session: session)
            await tableInfoChanges(session: session)
            await createStatements(session: session)
            await export(session: session)
            await dataExport(session: session)
            await exportFiles(session: session)
            await importing(session: session)
            await csvImporting(session: session)
            await clipboardImporting(session: session)
            await tableMaintenance(session: session)
            await definitions(session: session)
            await databaseActions(model: model, session: session)
            await userAccounts(session: session)
            await serverVariables(session: session)
            await processList(session: session)
            await settings(session: session)
            await connectionFiles(session: session)
            await viewEncoding(session: session)
            await sqliteFiles(model: model, session: session)
            about()
            await mcpServer(model: model, session: session)
            agentSetup()
            await querying(session: session)
            await console(session: session)
            await menuBar(model: model, session: session)
            await connectionLoss(session: session)
            session.disconnect()
            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    /// Waits up to a second for state that SwiftUI updates on its next pass.
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<50 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Waits for `window`'s alert or sheet to be on screen and done animating in. Answering a
    /// SwiftUI alert while it still slides in closes it inside a layout pass, and AppKit's
    /// nested animation crashes there (EXC_BAD_ACCESS at 0, FIXLOG); a person can't click that fast.
    static func sheetSettles(on window: NSWindow?) async {
        await until { window?.attachedSheet != nil }
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// Every main-menu item that matches, depth first.
    static func menuItems(where matches: (NSMenuItem) -> Bool) -> [NSMenuItem] {
        func search(_ menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { (matches($0) ? [$0] : []) + search($0.submenu) }
        }
        return search(NSApp.mainMenu)
    }

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// A menu bar item by title, after SwiftUI refreshes the menus as it does
    /// when one opens (until then an item keeps its old enabled state).
    static func menuItem(_ title: String) -> NSMenuItem? {
        func refresh(_ menu: NSMenu?) {
            guard let menu else { return }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            menu.items.forEach { refresh($0.submenu) }
        }
        refresh(NSApp.mainMenu)
        return menuItems { $0.title == title }.first
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}

/// Measures the longest gap between main-thread ticks while work runs elsewhere.
@MainActor
final class MainThreadMonitor {
    private var timer: Timer?
    private var last = ContinuousClock.now
    private var longest: Duration = .zero

    init() {
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = ContinuousClock.now
        longest = max(longest, now - last)
        last = now
    }

    func stop() -> Duration {
        tick()
        timer?.invalidate()
        return longest
    }
}
