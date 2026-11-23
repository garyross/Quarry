import AppKit
import QuarryKit

/// File > Import… (⇧⌘I): run a .sql or .sql.gz file (S-044), or load a CSV
/// file into a table (S-045), or the same from the clipboard (S-046).
extension Session {
    /// Connected, and no export or import sheet open. A database need not be
    /// selected: a file's own USE and CREATE DATABASE statements pick one.
    var canImport: Bool { phase == .connected && !isReadOnly && client != nil && importer == nil && exporter == nil }

    /// The selected table, a CSV file's first target (S-045).
    private var importTable: String? {
        selectedObject.flatMap { $0.kind == .table ? $0.name : nil }
    }

    /// The Import sheet for `file`, into the selected database.
    func requestImport(file: URL? = nil) {
        guard canImport, let client else { return }
        importer = Importer(database: database, table: importTable, client: client, file: file)
    }

    /// The menu item: an open panel first, then the sheet with the chosen file.
    func chooseImportFile() {
        guard canImport, let client else { return }
        let picking = Importer(database: database, table: importTable, client: client)
        ImportSheet.chooseFile(for: picking) { [weak self] in
            guard let self, self.canImport else { return }
            self.importer = picking
        }
    }

    /// File > Import from Clipboard… (S-046): the clipboard's text in the
    /// Import sheet, SQL or CSV as it reads; an alert when it holds none.
    func importFromClipboard(_ text: String? = NSPasteboard.general.string(forType: .string)) {
        guard canImport, let client else { return }
        guard let text, !text.allSatisfy(\.isWhitespace) else { return ImportSheet.alertNoClipboardText() }
        importer = Importer(database: database, table: importTable, client: client, clipboard: text)
    }

    /// Closes the sheet; after an import that ran, the databases and the
    /// sidebar reload to show what it made.
    func closeImport() {
        let ran = importer.map { $0.summary != nil || $0.wasCancelled || $0.error != nil } ?? false
        importer?.discardClipboardFile()
        importer = nil
        if ran { refresh() }
    }
}
