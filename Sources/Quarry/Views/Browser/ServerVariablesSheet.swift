import AppKit
import QuarryKit
import SwiftUI
import UniformTypeIdentifiers

/// Database > Show Server Variables… (⇧⌘V, S-052): every variable and its
/// value, a filter over names and values, Copy in three forms, and Save As…
/// in my.cnf's "name = value" form.
struct ServerVariablesSheet: View {
    @Bindable var list: VariableList
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                Text("Server Variables")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                TextField("Filter", text: $list.search, prompt: Text("Filter"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Layout.variablesFilterWidth)
                    .help("Show the variables whose name or value contains this text")
            }
            .padding(Space.margin)
            Divider()
            table
                .overlay { emptyState }
                .frame(height: Layout.variablesTableHeight)
            Divider()
            HStack(spacing: Space.sm) {
                Text(list.countText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(list.saveTitle, action: save)
                    .disabled(list.shown.isEmpty)
                    .help(list.isFiltering ? "Save the variables shown to a .cnf file" : "Save every variable to a .cnf file")
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .gridProbe("buttons", area: "server-variables")
            .padding(Space.margin)
        }
        .frame(width: Layout.variablesWidth)
        .gridArea("server-variables", inset: 0)
        .noInitialFocus()
        .onExitCommand(perform: close)
    }

    private var table: some View {
        Table(list.shown, selection: $list.selection) {
            TableColumn("Variable") { variable in
                Text(variable.name).lineLimit(1)
            }
            .width(min: Layout.variablesNameMin, ideal: Layout.variablesNameWidth)
            TableColumn("Value") { variable in
                Text(variable.value)
                    .font(DataStyle.gridFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(variable.value)
            }
        }
        .contextMenu(forSelectionType: ServerVariable.ID.self) { ids in
            let many = ids.count > 1
            Button("Copy") { list.copy(.both, ids) }
            Button(many ? "Copy Variable Names" : "Copy Variable Name") { list.copy(.name, ids) }
            Button(many ? "Copy Variable Values" : "Copy Variable Value") { list.copy(.value, ids) }
        }
        .onCopyCommand {
            let text = ServerVariable.copyText(list.selected(), .both)
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
        .accessibilityLabel("Server variables")
    }

    @ViewBuilder private var emptyState: some View {
        if let error = list.error {
            ContentUnavailableView {
                Label("Can’t Read Variables", systemImage: StatusStyle.errorSymbol)
            } description: {
                Text(error.message).textSelection(.enabled)
            }
        } else if list.isLoading {
            ProgressView().controlSize(.small).accessibilityLabel("Loading variables")
        } else if list.shown.isEmpty {
            ContentUnavailableView.search(text: list.search)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cnf") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "ServerVariables.cnf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try list.save(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
