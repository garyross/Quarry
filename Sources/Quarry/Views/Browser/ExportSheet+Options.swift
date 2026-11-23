import QuarryKit
import SwiftUI

/// The CSV options of the Export sheet (S-042), Sequel Pro's: how fields are
/// separated, enclosed and escaped, how lines end, a header row, and NULL's text.
struct ExportCSVOptions: View {
    @Bindable var exporter: Exporter

    var body: some View {
        Section("Options") {
            CSVFormatPickers(format: $exporter.csv, reading: false)
            ExportCompression(exporter: exporter)
        }
    }
}

/// JSON and XML have no choices of their own beyond compression; a line says
/// what the file holds.
struct ExportDataOptions: View {
    @Bindable var exporter: Exporter

    var body: some View {
        Section {
            ExportCompression(exporter: exporter)
        } header: {
            Text("Options")
        } footer: {
            Text(exporter.format == .json
                 ? "Each row is an object; numbers and NULL keep their JSON types, other values are strings."
                 : "In mysqldump’s XML format: each row’s fields by name, NULL as xsi:nil.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct ExportCompression: View {
    @Bindable var exporter: Exporter

    var body: some View {
        Picker("Compression", selection: $exporter.compression) {
            Text("None").tag(SQLDump.Compression.none)
            Text("Gzip").tag(SQLDump.Compression.gzip)
        }
        .help("Gzip writes a smaller .gz file")
    }
}

/// The file name pattern with its token menu, one file per table, and the
/// name Export… will use (S-043).
struct ExportFileOptions: View {
    @Bindable var exporter: Exporter

    var body: some View {
        Section {
            LabeledContent("Name") {
                HStack(spacing: Space.sm) {
                    TextField("Name", text: $exporter.namePattern, prompt: Text("Default"))
                        .labelsHidden()
                        .help("Type a name, or add tokens such as {database} and {date}; empty uses the default name")
                    Menu("Insert") {
                        ForEach(ExportFileName.Token.allCases) { token in
                            Button(token.title) { exporter.insert(token) }
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .help("Add a token at the end of the name")
                    .accessibilityLabel("Insert token")
                }
            }
            if exporter.canSplit {
                Toggle("One file per table", isOn: $exporter.perTable)
                    .help("Write each checked item to its own file, in a folder you choose; {table} names them")
            }
            LabeledContent("Saves as") {
                Text(exporter.namePreview)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .help("The name Export… gives the save panel; you can still change it there")
        } header: {
            Text("File")
        }
    }
}
