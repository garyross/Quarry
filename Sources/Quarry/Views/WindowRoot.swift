import AppKit
import SwiftUI
import QuarryControllers

/// One window, one connection: the Connect page until connected, then the browser.
struct WindowRoot: View {
    static let sceneID = "connection"

    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var session = Session()

    var body: some View {
        Group {
            switch session.phase {
            case .disconnected, .connecting:
                ConnectView()
            case .connected:
                BrowserView()
            }
        }
        .environment(session)
        // S-055: on the window, so Open… works on the Connect page and Save in the browser.
        .sheet(item: $session.connectionFileDraft) { draft in
            ConnectionFileSheet(draft: draft, save: { session.chooseConnectionFileDestination() },
                                close: { session.connectionFileDraft = nil })
        }
        .sheet(item: $session.fileUnlock) { unlock in
            FileUnlockSheet(unlock: unlock, open: { session.unlockConnectionFile() }, close: { session.fileUnlock = nil })
        }
        // S-064: an agent's change waits here for Allow or Deny, connected or not.
        .sheet(item: $session.agentApproval) { approval in
            ApprovalSheet(approval: approval)
        }
        .modifier(WindowAlerts(session: session))
        .navigationTitle(session.title)
        .navigationSubtitle(session.subtitle)
        .background(KeyWindowHook(onWindow: { window in
            Tabs.claim(window: window, session: session, model: model)
        }, onKey: { MenuState.shared.activate(session) }))
        .onChange(of: session.menuSnapshot) { MenuState.shared.update(session) }
        .noInitialFocus()
        .task {
            Tabs.openWindow = openWindow
            session.openWindowAction = openWindow
            MenuState.shared.activate(session)
            SeedData.insertIfRequested(into: model)
            MCPHost.shared.configure(model: model)
            SelfTest.runIfRequested(model: model, session: session)
            Snapshot.runIfRequested(model: model, session: session, openSettings: openSettings)
        }
    }
}

/// Calls `onWindow` once, when the view first has a window (a new tab joins
/// its tab bar then), and `onKey` whenever that window becomes the key
/// window, so the menus follow the window people are using.
private struct KeyWindowHook: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    let onKey: () -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onWindow = onWindow
        probe.onKey = onKey
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) { probe.onKey = onKey }

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        var onKey: () -> Void = {}

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            if let onWindow {
                self.onWindow = nil
                onWindow(window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(becameKey),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
            if window.isKeyWindow { onKey() }
        }

        @objc private func becameKey(_ note: Notification) { onKey() }
    }
}

/// The window's one alert (`Session.alert`, `WindowAlert`): Empty or Delete Table
/// with Ignore foreign keys as its checkbox (S-022), Delete Database (S-019), or a
/// notice that something finished or failed. Two presenters, because only Empty
/// and Delete Table have the checkbox; both read the same value.
private struct WindowAlerts: ViewModifier {
    /// Passed in: the window's `.environment(session)` is applied inside this modifier.
    let session: Session

    func body(content: Content) -> some View {
        let alert = session.alert
        content
            .alert(alert?.title ?? "", isPresented: presented { $0.tableEdit != nil }) {
                Button(alert?.confirmTitle ?? "Delete", role: .destructive) { session.confirmTableEdit() }
                Button("Cancel", role: .cancel) { session.alert = nil }
            } message: {
                Text(alert?.message ?? "")
            }
            .dialogSeverity(.critical)
            .dialogSuppressionToggle("Ignore foreign keys", isSuppressed: Binding(
                get: { session.alert?.ignoreForeignKeys ?? false },
                set: { session.alert?.ignoreForeignKeys = $0 }))
            .alert(alert?.title ?? "", isPresented: presented { $0.tableEdit == nil }) {
                if alert?.databaseToDelete != nil {
                    Button("Delete", role: .destructive) { session.confirmDeleteDatabase() }
                    Button("Cancel", role: .cancel) { session.alert = nil }
                } else {
                    Button("OK") { session.alert = nil }
                }
            } message: {
                Text(alert?.message ?? "")
            }
            .dialogSeverity(alert?.isConfirmation == true ? .critical : .automatic)
    }

    /// Shown while the alert is one this presenter shows; dismissing clears it.
    private func presented(_ shows: @escaping (WindowAlert) -> Bool) -> Binding<Bool> {
        Binding(get: { session.alert.map(shows) ?? false }, set: { if !$0 { session.alert = nil } })
    }
}
