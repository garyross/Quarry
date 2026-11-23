import AppKit
import QuarryKit
import SwiftUI

/// Connection tabs (S-037). `open` asks for a new window and queues a request;
/// the new window's `WindowRoot` takes it, joins the requesting window's tab
/// bar and sets up its session.
@MainActor
enum Tabs {
    struct Request {
        weak var parent: NSWindow?
        /// Fills the new tab's session; nil leaves the Connect page, as ⌘N shows it.
        var setup: ((Session, AppModel) -> Void)?
    }

    struct Weak { weak var session: Session? }
    /// Every window's session, for Save Session… (S-055).
    private static var sessions: [Weak] = []

    /// Connected sessions by window, front window first, each window's tabs in tab-bar order.
    static func connectedWindows() -> [[Session]] {
        let live = sessions.compactMap(\.session).filter { $0.phase == .connected && $0.window != nil }
        var seen = Set<ObjectIdentifier>()
        var result: [[Session]] = []
        for window in NSApp.orderedWindows {
            let group = window.tabbedWindows ?? [window]
            guard let first = group.first, seen.insert(ObjectIdentifier(first)).inserted else { continue }
            let tabs = group.compactMap { tab in live.first { $0.window === tab } }
            if !tabs.isEmpty { result.append(tabs) }
        }
        return result
    }

    /// Every window's session, connected or not, front window first (S-064: where to ask).
    static func allSessions() -> [Session] {
        let live = sessions.compactMap(\.session).filter { $0.window != nil }
        return NSApp.orderedWindows.compactMap { window in live.first { $0.window === window } }
    }

    /// The window group's `openWindow`, set by every window as it appears.
    static var openWindow: OpenWindowAction?
    private static var pending: [Request] = []
    /// The session of the tab opened last (self-test, snapshots).
    private(set) static weak var lastOpened: Session?
    private(set) static weak var lastOpenedWindow: NSWindow?

    /// A new tab beside `parent` (the key window by default), or a new window when there is none.
    /// `using` is the asking window's own action: the shared one may belong to a
    /// window that has closed since, and then opens nothing (docs/FIXLOG.md).
    static func open(beside parent: NSWindow? = NSApp.keyWindow, using action: OpenWindowAction? = nil,
                     _ setup: ((Session, AppModel) -> Void)? = nil) {
        guard let openWindow = action ?? openWindow else { return }
        pending.append(Request(parent: parent?.tabbingMode == .disallowed ? nil : parent, setup: setup))
        openWindow(id: WindowRoot.sceneID)
    }

    /// Windows that have appeared; only a window appearing for the first time takes a request.
    /// Weak, so a new window that reuses a closed one's address still counts as new (docs/FIXLOG.md).
    private static let seen = NSHashTable<NSWindow>.weakObjects()

    /// Called whenever a window's root view gets its NSWindow.
    static func claim(window: NSWindow, session: Session, model: AppModel) {
        session.window = window
        sessions.removeAll { $0.session == nil }
        if !sessions.contains(where: { $0.session === session }) { sessions.append(Weak(session: session)) }
        guard !seen.contains(window) else { return }
        seen.add(window)
        guard !pending.isEmpty else {
            // S-049: a plain new window selects the default connection, or the one used last.
            session.showInitialConnection(model: model)
            return
        }
        let request = pending.removeFirst()
        if let parent = request.parent, parent !== window, !(parent.tabbedWindows?.contains(window) ?? false) {
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        lastOpened = session
        lastOpenedWindow = window
        if let setup = request.setup { setup(session, model) } else { session.showInitialConnection(model: model) }
    }
}

extension Session {
    /// A new tab on this server, with its own connection, showing `place`.
    func openInNewTab(_ place: Place) {
        guard phase == .connected, let details = connectedDetails else { return }
        let saved = selectedSaved
        Tabs.open(beside: window ?? NSApp.keyWindow, using: openWindowAction) { tab, model in
            tab.form = details
            tab.selectedSaved = saved
            tab.pendingPlace = place
            tab.connect(model: model)
        }
    }

    /// File > Duplicate Connection Tab (⇧⌘T): the same server, database, object and view (S-040).
    func duplicateTab() {
        guard phase == .connected, let details = connectedDetails else { return }
        let saved = selectedSaved
        let place = currentPlace
        Tabs.open(beside: window ?? NSApp.keyWindow, using: openWindowAction) { tab, model in
            tab.form = details
            tab.selectedSaved = saved
            tab.pendingPlace = place
            tab.connect(model: model)
        }
    }

    /// Where an object opens: Content, or Info for a routine.
    func place(for objectID: String) -> Place? {
        guard let database, let object = objects.first(where: { $0.id == objectID }) else { return nil }
        return Place(database: database, objectID: objectID,
                     view: DetailView.content.applies(to: object.kind) ? .content : .info, content: nil)
    }

    /// ⌘-click in the sidebar, or Table > Open Table in New Tab (⌃⌘T).
    func openObjectInNewTab(_ objectID: String? = nil) {
        guard let id = objectID ?? selectedObjectID, let place = place(for: id) else { return }
        openInNewTab(place)
    }

    /// "Open Table in New Tab", named for the object's kind as in Sequel Pro.
    static func openInNewTabTitle(_ kind: ObjectKind?) -> String {
        switch kind {
        case .view: "Open View in New Tab"
        case .procedure: "Open Procedure in New Tab"
        case .function: "Open Function in New Tab"
        case .table, nil: "Open Table in New Tab"
        }
    }

    /// ⌘-click on a foreign-key arrow: the referenced row in a new tab.
    func followLinkInNewTab(row: Int, column: Int) {
        guard let place = linkPlace(row: row, column: column) else { return }
        openInNewTab(place)
    }

    /// Table > Open Referenced Row in New Tab (⌥⌘↓).
    func openReferencedRowInNewTab() {
        guard content.selection.count == 1, let row = content.selection.first,
              let column = content.followableLinks(row: row).first else { return }
        followLinkInNewTab(row: row, column: column)
    }
}
