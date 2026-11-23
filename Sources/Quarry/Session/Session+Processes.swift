import Foundation
import QuarryKit

/// Database > Show Server Processes… (S-053).
extension Session {
    /// ⌥⌘P: opens this window's process list, or brings it to the front.
    func requestProcessList() {
        guard phase == .connected, !isSQLite, let client, let details = connectedDetails else { return }
        if let id = processListID, ProcessList.open[id] != nil {
            Tabs.openWindow?(id: ProcessListWindow.sceneID, value: id)
            return
        }
        let list = ProcessList(server: details.displayName, source: client)
        ProcessList.open[list.id] = list
        processListID = list.id
        Tabs.openWindow?(id: ProcessListWindow.sceneID, value: list.id)
    }

    /// Disconnect closes the process list's connection too; its window says so.
    func stopProcessList() {
        if let id = processListID { ProcessList.open[id]?.stop() }
        processListID = nil
    }
}
