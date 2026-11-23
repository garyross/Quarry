import AppKit
import QuarryKit
import SwiftUI
import UniformTypeIdentifiers

/// The Export sheet (S-041, S-042): a format (SQL, CSV, JSON, XML) and, for
/// the data formats, a source (tables, Content's rows, the query result); the
/// database's objects with Structure, Content and Drop checkboxes for SQL or
/// one checkbox for the others; the format's options; then a save panel and a
/// progress bar with Cancel. Return exports, Escape cancels.
struct ExportSheet: View {
    @Bindable var exporter: Exporter
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(exporter.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
                .padding([.horizontal, .top], Space.margin)
                .padding(.bottom, Space.sm)
            formatBar
                .gridProbe("format", area: "export", edge: nil)
                .padding(.horizontal, Space.margin)
                .padding(.bottom, Space.sm)
            if exporter.source == .tables {
                objectList
                    .gridProbe("objects", area: "export")
                    .padding(.horizontal, Space.margin)
            }
            Form {
                if exporter.source != .tables { sourceSummary }
                switch exporter.format {
                case .sql: options
                case .csv: ExportCSVOptions(exporter: exporter)
                case .json, .xml: ExportDataOptions(exporter: exporter)
                }
                ExportFileOptions(exporter: exporter)
                status
            }
            .formStyle(.grouped)
            .fitsContent()
            .disabled(exporter.isWorking)
            buttons
                .gridProbe("buttons", area: "export")
                .padding([.horizontal, .bottom], Space.margin)
        }
        .frame(width: Layout.exportSheetWidth)
        .gridArea("export")
    }

    // MARK: Format and source

    private var formatBar: some View {
        HStack(spacing: Space.md) {
            Picker("Format", selection: $exporter.format) {
                ForEach(Exporter.Format.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("SQL writes a script that rebuilds the items; CSV, JSON and XML write their rows")
            Spacer(minLength: 0)
            Picker("Source", selection: $exporter.source) {
                ForEach(exporter.sources) { Text(exporter.title(of: $0)).tag($0) }
            }
            .frame(maxWidth: Layout.exportSourceWidth)
            .disabled(exporter.sources.count < 2)
            .help("Whole tables, the rows Content shows under its filter and sort, or the last query’s result")
        }
        .disabled(exporter.isWorking)
    }

    /// What a filtered content or query result export writes.
    private var sourceSummary: some View {
        Section {
            LabeledContent("Rows") {
                Text(exporter.sourceSummary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Objects

    @ViewBuilder private var objectTable: some View {
        if exporter.format == .sql {
            sqlTable
        } else {
            Table(exporter.dataRows) {
                TableColumn("Name") { row in
                    Label(row.object.name, systemImage: ObjectSidebar.symbol(row.object.kind))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("Export") { row in
                    Toggle("Export", isOn: Binding(
                        get: { row.include },
                        set: { on in
                            guard let index = exporter.rows.firstIndex(where: { $0.id == row.id }) else { return }
                            exporter.rows[index].include = on
                        }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("Export \(row.object.name)")
                        .frame(maxWidth: .infinity)
                }
                .width(Layout.exportCheckColumn)
            }
        }
    }

    private var objectList: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            objectTable
            .frame(height: Layout.exportListHeight)
            .disabled(exporter.isWorking)
            HStack(spacing: Space.sm) {
                Button("Check All") { exporter.setAll(true) }
                    .help("Check every item")
                Button("Uncheck All") { exporter.setAll(false) }
                    .help("Clear every checkbox, to pick a few items")
                Spacer()
                Text(exporter.nothingChecked ?? exporter.checkedSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .disabled(exporter.isWorking)
        }
    }

    private var sqlTable: some View {
        Table(exporter.rows) {
                TableColumn("Name") { row in
                    Label(row.object.name, systemImage: ObjectSidebar.symbol(row.object.kind))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("Structure") { row in check(row, \.structure, "Structure") }
                    .width(Layout.exportCheckColumn)
                TableColumn("Content") { row in
                    if row.hasContent {
                        check(row, \.content, "Content")
                    } else {
                        Text("–")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("No content")
                    }
                }
                .width(Layout.exportCheckColumn)
                TableColumn("Drop") { row in check(row, \.drop, "Drop") }
                    .width(Layout.exportCheckColumn)
        }
    }

    private func check(_ row: Exporter.Row, _ part: WritableKeyPath<SQLDump.Part, Bool>, _ name: String) -> some View {
        Toggle(name, isOn: Binding(
            get: { row.part[keyPath: part] },
            set: { on in
                guard let index = exporter.rows.firstIndex(where: { $0.id == row.id }) else { return }
                exporter.rows[index].part[keyPath: part] = on
            }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("\(name) of \(row.object.name)")
            .frame(maxWidth: .infinity)
    }

    // MARK: Options

    @ViewBuilder private var options: some View {
        Section("Options") {
            if exporter.showsServerOptions {
                Toggle("Auto-increment values", isOn: $exporter.autoIncrement)
                    .help("Keep AUTO_INCREMENT=n, so new rows continue the numbering")
            }
            LabeledContent("New INSERT every") {
                HStack(spacing: Space.sm) {
                    TextField("Size", value: $exporter.batchSize, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: Layout.exportBatchField)
                    Picker("Unit", selection: $exporter.batchUnit) {
                        ForEach(Exporter.BatchUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .help("Rows go in multi-row INSERTs; a new one starts after this much data or this many rows")
            if exporter.showsServerOptions {
                Toggle("BLOBs as hex", isOn: $exporter.hexBlobs)
                    .help("Write binary columns as X'…', so the file survives any editor. Bytes that aren’t text are always hex")
            }
            Picker("Compression", selection: $exporter.compression) {
                Text("None").tag(SQLDump.Compression.none)
                Text("Gzip").tag(SQLDump.Compression.gzip)
            }
            .help("Gzip writes a smaller .sql.gz file")
        }
    }

    @ViewBuilder private var status: some View {
        if let error = exporter.error {
            Section {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: StatusStyle.errorSymbol).foregroundStyle(StatusStyle.error)
                }
                .accessibilityLabel("Error: \(error)")
            }
        } else if let finished = exporter.finishedText {
            Section {
                Label {
                    Text(finished)
                } icon: {
                    Image(systemName: StatusStyle.successSymbol).foregroundStyle(StatusStyle.success)
                }
            }
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if let progress = exporter.progress {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Export progress")
                Text(progress.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.updatesFrequently)
                Button("Cancel", role: .cancel, action: exporter.cancel)
                    .keyboardShortcut(.cancelAction)
                    .help("Stop the export and delete the unfinished file (Escape)")
            } else {
                if exporter.wasCancelled {
                    Text("Export cancelled.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if exporter.finishedFile != nil {
                    Button("Show in Finder", action: exporter.showInFinder)
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel", role: .cancel, action: close)
                        .keyboardShortcut(.cancelAction)
                    Button("Export…", action: choosePlace)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!exporter.canExport)
                        .help(exporter.splitsFiles ? "Choose a folder for the files (Return)"
                              : "Choose where to save \(exporter.fileName) (Return)")
                }
            }
        }
    }

    private func choosePlace() {
        guard let window = NSApp.keyWindow else { return }
        if exporter.splitsFiles {
            chooseFolder(window)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exporter.fileName
        let plain: UTType = switch exporter.format {
        case .sql: UTType(filenameExtension: "sql") ?? .plainText
        case .csv: .commaSeparatedText
        case .json: .json
        case .xml: .xml
        }
        panel.allowedContentTypes = [exporter.compression == .gzip ? (UTType(filenameExtension: "gz") ?? .data) : plain]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            exporter.start(to: url)
        }
    }

    /// One file per table: a folder, then an alert if files there would be replaced.
    private func chooseFolder(_ window: NSWindow) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for \(exporter.perTableNames().count) files"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            let existing = exporter.existingFiles(in: folder)
            guard !existing.isEmpty else {
                exporter.start(to: folder)
                return
            }
            let alert = NSAlert()
            alert.messageText = existing.count == 1
                ? "Replace \u{201C}\(existing[0])\u{201D}?"
                : "Replace \(existing.count) files in \u{201C}\(folder.lastPathComponent)\u{201D}?"
            alert.informativeText = "Files with these names already exist. Exporting writes over them."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { answer in
                if answer == .alertFirstButtonReturn { exporter.start(to: folder) }
            }
        }
    }
}
