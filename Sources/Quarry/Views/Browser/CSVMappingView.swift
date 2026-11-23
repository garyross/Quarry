import QuarryKit
import QuarryControllers
import SwiftUI

/// The Import sheet's CSV options (S-045), the Export sheet's words: how
/// fields are separated, enclosed and escaped, how lines end, the first row's
/// field names, and NULL's text.
struct ImportCSVOptions: View {
    @Bindable var importer: Importer
    @Bindable var csv: CSVImporter

    var body: some View {
        Section {
            CSVFormatPickers(format: $csv.format, reading: true)
        } header: {
            Text("CSV Options")
        } footer: {
            if importer.database == nil {
                Text("Select a database first: a CSV file goes into one of its tables.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(importer.isWorking)
    }
}

/// The field mapping (S-045), Sequel Pro's: the target table (or a new one),
/// INSERT, REPLACE or UPDATE, how columns line up with fields, and a grid of
/// the table's fields with the column that fills each and the previewed
/// record's value. `extra` holds the sheet's error question and result.
struct CSVMappingView<Extra: View>: View {
    @Bindable var importer: Importer
    @Bindable var csv: CSVImporter
    @ViewBuilder var extra: Extra

    var body: some View {
        Form {
            target
            Section {
                MappingGrid(csv: csv)
                    .frame(height: Layout.csvMappingGridHeight)
            } header: {
                HStack(spacing: Space.sm) {
                    Text("Fields")
                    Spacer()
                    recordStepper
                }
            } footer: {
                if let problem = csv.problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            extra
        }
        .formStyle(.grouped)
        .fitsContent()
        .disabled(importer.isWorking)
    }

    private var target: some View {
        Section {
            Picker("Table", selection: Binding(get: { csv.target }, set: { importer.chooseTarget($0) })) {
                ForEach(csv.tables, id: \.self) { Text($0).tag(CSVImporter.Target.table($0)) }
                if !csv.tables.isEmpty { Divider() }
                Text("New Table").tag(CSVImporter.Target.newTable)
            }
            .help("The table the rows go into, or a new one made from the file’s columns")
            if csv.isNewTable {
                TextField("Name", text: $csv.newTableName, prompt: Text("Table name"))
                    .help("The new table’s name; its fields and types are below, guessed from the first records")
            } else {
                Picker("Import method", selection: Binding(get: { csv.mapping.method }, set: { csv.setMethod($0) })) {
                    ForEach(CSVMapping.Method.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("INSERT adds rows; REPLACE overwrites rows with the same key; UPDATE changes the rows the Match fields find")
                Picker("Align by", selection: Binding(get: { csv.alignment }, set: { csv.align($0) })) {
                    ForEach(CSVMapping.Alignment.allCases.filter { $0 != .custom || csv.alignment == .custom }) { alignment in
                        Text(alignment.title).tag(alignment)
                            .selectionDisabled(alignment == .matchingNames && !csv.header)
                    }
                }
                .help("How the file’s columns line up with the fields; pick a column below to set your own")
            }
            Toggle("Field names in the first row", isOn: $csv.format.header)
            if !csv.isNewTable, csv.mapping.method == .insert {
                Toggle("Skip rows whose key exists", isOn: Binding(get: { csv.mapping.ignoreDuplicates },
                                                                    set: { csv.setIgnoreDuplicates($0) }))
                    .help((csv.engine == .sqlite ? "INSERT OR IGNORE" : "INSERT IGNORE")
                          + ": a row with a primary or unique key already in the table is left out, not an error")
            }
        }
    }

    private var recordStepper: some View {
        HStack(spacing: Space.xs) {
            Text(csv.recordText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                csv.step(by: -1)
            } label: {
                Label("Previous Record", systemImage: "chevron.left")
            }
            .disabled(csv.record == 0)
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .help("Preview the previous record (⌥⌘←)")
            Button {
                csv.step(by: 1)
            } label: {
                Label("Next Record", systemImage: "chevron.right")
            }
            .disabled(csv.record >= csv.dataRecords.count - 1)
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .help("Preview the next record (⌥⌘→)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .textCase(nil)
    }
}

/// One row per field: its name and type (editable for a new table), the
/// column that fills it, Match for UPDATE, and the previewed value.
private struct MappingGrid: View {
    @Bindable var csv: CSVImporter

    private struct Row: Identifiable {
        let id: Int
    }

    var body: some View {
        Table(csv.mapping.fields.indices.map(Row.init)) {
            TableColumn("Field") { row in
                if csv.isNewTable {
                    TextField("Name", text: Binding(get: { csv.newFields.indices.contains(row.id) ? csv.newFields[row.id].name : "" },
                                                    set: { csv.renameNewField(row.id, to: $0) }))
                        .labelsHidden()
                } else {
                    Text(csv.fieldName(row.id))
                        .lineLimit(1)
                }
            }
            TableColumn("Type") { row in
                if csv.isNewTable {
                    TextField("Type", text: Binding(get: { csv.type(of: row.id) },
                                                    set: { csv.setNewFieldType(row.id, to: $0) }))
                        .labelsHidden()
                        .font(.body.monospaced())
                } else {
                    Text(csv.type(of: row.id))
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            TableColumn("Import From") { row in
                Picker("Import From", selection: Binding(get: { csv.source(of: row.id) },
                                                         set: { csv.setSource($0, for: row.id) })) {
                    Text("Don’t Import").tag(Int?.none)
                    Divider()
                    ForEach(Array(csv.columns.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(Int?.some(index))
                    }
                }
                .labelsHidden()
                .help("The file’s column that fills this field")
            }
            .width(Layout.csvColumnPopupWidth)
            TableColumn("Match") { row in
                Toggle("Match", isOn: Binding(get: { csv.isMatch(row.id) },
                                              set: { csv.setMatch($0, for: row.id) }))
                    .labelsHidden()
                    .disabled(csv.mapping.method != .update || csv.source(of: row.id) == nil)
                    .help("UPDATE finds each row by the Match fields’ values")
            }
            .width(Layout.csvMatchColumn)
            TableColumn("Value") { row in
                if let value = csv.previewValue(for: row.id) {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("NULL")
                        .italic()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .accessibilityLabel("Field mapping")
    }
}
