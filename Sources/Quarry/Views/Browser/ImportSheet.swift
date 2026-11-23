import AppKit
import QuarryKit
import SwiftUI
import UniformTypeIdentifiers

/// The Import sheet (S-044): the file, its encoding and what to do on an
/// error, then a progress bar with Cancel. With On an error set to Ask Me, a
/// failed statement pauses the import here with Continue, Skip All Errors and
/// Stop. Return imports, Escape cancels. A CSV file (S-045) has its own
/// options, then Next shows the field mapping in the same sheet.
struct ImportSheet: View {
    @Bindable var importer: Importer
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(importer.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
                .padding([.horizontal, .top], Space.margin)
            if importer.isMapping {
                CSVMappingView(importer: importer, csv: importer.csv) {
                    if let failure = importer.pendingFailure { errorQuestion(failure) }
                    status
                }
            } else {
                Form {
                    fileSection
                    if importer.format == .csv { ImportCSVOptions(importer: importer, csv: importer.csv) }
                    if let failure = importer.pendingFailure { errorQuestion(failure) }
                    status
                }
                .formStyle(.grouped)
                .fitsContent()
            }
            buttons
                .gridProbe("buttons", area: "import")
                .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: importer.isMapping ? Layout.csvMappingWidth : Layout.importSheetWidth)
        .gridArea("import")
        .noInitialFocus()
    }

    private var fileSection: some View {
        Section {
            if let clipboard = importer.clipboard {
                LabeledContent("Clipboard") {
                    HStack(spacing: Space.sm) {
                        Text(importer.fileSummary ?? "")
                        Button("Choose File…") { ImportSheet.chooseFile(for: importer) }
                            .help("Import a .sql, .sql.gz, .csv or .tsv file instead")
                    }
                }
                Text(ClipboardText.preview(clipboard))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(Layout.clipboardPreviewLines)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Clipboard text")
            } else {
                LabeledContent("File") {
                    HStack(spacing: Space.sm) {
                        Text(importer.fileSummary ?? "None")
                            .foregroundStyle(importer.file == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { ImportSheet.chooseFile(for: importer) }
                            .help("Pick a .sql, .sql.gz, .csv or .tsv file")
                    }
                }
            }
            Picker("Format", selection: $importer.format) {
                ForEach(Importer.Format.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help(importer.clipboard == nil ? "SQL runs the file’s statements; CSV loads its rows into a table"
                  : "SQL runs the text’s statements; CSV loads its rows into a table. Cells copied from a spreadsheet are CSV with Tab")
            if importer.clipboard == nil {
                Picker("Encoding", selection: $importer.encoding) {
                    ForEach(Importer.Encoding.allCases) { Text($0.title).tag($0) }
                }
                .help("How the file’s text is stored. Quarry’s and mysqldump’s files are UTF-8")
            }
            Picker("On an error", selection: $importer.errorPolicy) {
                ForEach(Importer.ErrorPolicy.allCases) { Text($0.title).tag($0) }
            }
            .help("What happens when the server refuses a statement")
        } footer: {
            Text(importer.format == .sql
                 ? "Statements run one at a time and stay in the database; an import isn’t undone."
                 : "Rows go in by batches of up to 1,000 and stay in the database; an import isn’t undone.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .disabled(importer.isWorking)
    }

    // MARK: Errors

    private func errorQuestion(_ failure: ImportFailure) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(failure.text).textSelection(.enabled)
                    Text(failure.statement)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            } icon: {
                Image(systemName: StatusStyle.errorSymbol).foregroundStyle(StatusStyle.error)
            }
            .accessibilityLabel("Error: \(failure.text)")
            HStack(spacing: Space.sm) {
                Spacer()
                Button("Stop") { importer.answer(.stop) }
                    .help("End the import here; what ran stays")
                Button("Skip All Errors") { importer.answer(.skipAll) }
                    .help("Skip this statement and every later one that fails, without asking")
                Button("Continue") { importer.answer(.continue) }
                    .keyboardShortcut(.defaultAction)
                    .help("Skip this statement and go on (Return)")
            }
        } header: {
            Text("A statement failed")
        }
    }

    @ViewBuilder private var status: some View {
        if let error = importer.error ?? (importer.isMapping ? nil : importer.csv.loadError) {
            Section {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: StatusStyle.errorSymbol).foregroundStyle(StatusStyle.error)
                }
                .accessibilityLabel("Error: \(error)")
            }
        } else if let summary = importer.summary, let finished = importer.finishedText {
            Section {
                Label {
                    Text(finished)
                } icon: {
                    if summary.failures.isEmpty {
                        Image(systemName: StatusStyle.successSymbol).foregroundStyle(StatusStyle.success)
                    } else {
                        Image(systemName: StatusStyle.warningSymbol).foregroundStyle(StatusStyle.warning)
                    }
                }
                if !summary.failures.isEmpty {
                    DisclosureGroup("Errors") {
                        ScrollView {
                            Text(summary.failures.map(\.text).joined(separator: "\n"))
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: Layout.importErrorsHeight)
                    }
                }
            }
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if importer.isWorking {
                ProgressView(value: importer.progress?.fraction ?? 0)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Import progress")
                Text(importer.pendingFailure == nil ? importer.progress?.text ?? "Connecting…" : "Waiting for you")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.updatesFrequently)
                Button("Cancel", role: .cancel, action: importer.cancel)
                    .keyboardShortcut(.cancelAction)
                    .help("Stop the import; what ran stays in the database (Escape)")
            } else {
                if importer.isMapping {
                    Button("Back", action: importer.back)
                        .help("Change how the file is read")
                }
                if importer.wasCancelled {
                    Text(importer.cancelledText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if importer.isFinished, !importer.wasCancelled {
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else if importer.format == .csv, !importer.isMapping {
                    if importer.csv.isLoading { ProgressView().controlSize(.small) }
                    Button("Cancel", role: .cancel, action: close)
                        .keyboardShortcut(.cancelAction)
                    Button("Next") { Task { await importer.next() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!importer.canGoNext)
                        .help(importer.database == nil ? "Select a database to import into first"
                              : importer.file == nil ? "Choose a file first" : "Map the file’s columns to a table’s fields (Return)")
                } else {
                    Button("Cancel", role: .cancel, action: close)
                        .keyboardShortcut(.cancelAction)
                    Button("Import") { importer.start() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!importer.canImport)
                        .help(importer.isMapping ? importer.csv.problem ?? "Import the rows into \u{201C}\(importer.csv.tableName)\u{201D} (Return)"
                              : importer.sourceName.map { "Run \($0) (Return)" } ?? "Choose a file first")
                }
            }
        }
    }

    /// Import from Clipboard with nothing to import.
    static func alertNoClipboardText() {
        let alert = NSAlert()
        alert.messageText = "The clipboard holds no text"
        alert.informativeText = "Copy SQL statements, or cells from a spreadsheet, and choose Import from Clipboard again."
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// The open panel for a .sql or .sql.gz file, on the key window.
    static func chooseFile(for importer: Importer, then: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sql"), UTType(filenameExtension: "gz"), .plainText,
                                     .commaSeparatedText, .tabSeparatedText]
            .compactMap { $0 }
        panel.prompt = "Choose"
        panel.message = "Choose a SQL or CSV file to import"
        let picked: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            importer.choose(url)
            then?()
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: picked)
        } else {
            picked(panel.runModal())
        }
    }
}
