import AppKit
import QuarryKit
import SwiftUI
import UniformTypeIdentifiers

/// Show Create Statement (S-028): the selected objects' CREATE statements,
/// colored like the editor and read-only. Copy, Save As…, Done.
struct CreateStatementSheet: View {
    @Bindable var sheet: CreateStatementSheetModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(sheet.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            statement
                .frame(minWidth: Layout.createStatementMinWidth, maxWidth: .infinity,
                       minHeight: Layout.createStatementMinHeight, maxHeight: .infinity)
                .background(.background)
                .clipShape(.rect(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(.separator))
                .gridProbe("statement", area: "create-statement")
            if let problem = sheet.saveError {
                Label(problem, systemImage: StatusStyle.errorSymbol)
                    .foregroundStyle(StatusStyle.error)
                    .font(.callout)
                    .accessibilityLabel("Error: \(problem)")
            }
            buttons
                .gridProbe("buttons", area: "create-statement")
        }
        .padding(Space.margin)
        .gridArea("create-statement")
        .onChange(of: sheet.text) { sheet.copied = false }
    }

    @ViewBuilder
    private var statement: some View {
        if sheet.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading the create statement")
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(SQLText.highlighted(sheet.text))
                    .font(.system(size: DataStyle.editorSize, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(Space.sm)
            }
            // A two-way scroll view centers short content; statements read from the top left.
            .defaultScrollAnchor(.topLeading)
            .accessibilityLabel("Create statement")
        }
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            Button("Save As…", action: save)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(sheet.isLoading)
                .help("Save the statement as \(sheet.fileName) (⇧⌘S)")
            Spacer()
            if sheet.copied {
                Label("Copied", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Button("Copy", action: sheet.copy)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(sheet.isLoading)
                .help("Copy the whole statement (⇧⌘C)")
            Button("Done", action: close)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .help("Close (Return or Escape)")
        }
        .background { Button("", action: close).keyboardShortcut(.cancelAction).hidden() }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sheet.fileName
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText]
        let text = sheet.text
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                sheet.saveError = nil
            } catch {
                sheet.saveError = "Couldn’t save \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}
