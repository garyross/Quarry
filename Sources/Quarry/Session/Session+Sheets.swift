import Foundation

/// Every sheet, alert and inline editor a window shows, in one list (review 2026-11-19 M6).
/// The window's alerts are one value, `alert` (review 2026-11-20 controllers, card 3).
extension Session {
    /// Clears them all, the way the snapshot run needs between pages and before
    /// it quits (an open sheet refuses terminate). A new sheet model on Session goes here.
    func closeSheets() {
        fieldEditor = nil
        bitEditor = nil
        newDatabase = nil
        databaseEditor = nil
        userManager = nil
        serverVariables = nil
        connectionFileDraft = nil
        fileUnlock = nil
        goToDatabase = nil
        newTable = nil
        tableDuplicator = nil
        createStatementSheet = nil
        exporter = nil
        importer?.cancel()
        importer = nil
        alert = nil
        renamingObjectID = nil
        structure.fieldSheet = nil
        structure.indexSheet = nil
        foreignKeys.sheet = nil
        triggers.sheet = nil
        definitionDraft = nil
        saveQueryDraft = nil
        connectionLost = false
        reconnectProblem = nil
        sshQuestion = nil
        agentApproval?.answer(false)
        agentApproval = nil
    }
}
