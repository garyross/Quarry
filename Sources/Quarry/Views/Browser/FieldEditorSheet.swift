import AppKit
import QuarryKit
import SwiftUI
import UniformTypeIdentifiers

/// The Field Editor (S-012): one value at length, as Text, Image or Hex.
/// Save (⌘Return) writes it as an inline edit would; Escape cancels.
struct FieldEditorSheet: View {
    @Bindable var editor: FieldEditor
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header
            pane
                .frame(minWidth: Layout.fieldEditorMinWidth, maxWidth: .infinity,
                       minHeight: Layout.fieldEditorMinHeight, maxHeight: .infinity)
                .clipShape(.rect(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(.separator))
            messages
            buttons
        }
        .padding(Space.margin)
        .gridArea("field-editor")
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Text(editor.summary)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.md)
            if editor.modes.count > 1 {
                Picker("Show As", selection: $editor.mode) {
                    ForEach(editor.modes) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show the value as text, as a picture, or as bytes")
            }
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch editor.mode {
        case .text:
            TextArea(text: $editor.text, isEditable: editor.isEditable, focusesOnAppear: editor.isEditable,
                     accessibilityLabel: editor.fieldName)
        case .image:
            if let image = editor.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                    .accessibilityLabel("Picture, \(Int(image.size.width)) by \(Int(image.size.height))")
            } else {
                ContentUnavailableView("Not an Image", systemImage: "photo",
                                       description: Text("These bytes aren't a picture Quarry can show."))
            }
        case .hex:
            TextArea(text: .constant(editor.hexDump), isEditable: false, wraps: false, accessibilityLabel: "Bytes in hexadecimal")
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let problem = editor.jsonProblem {
            Label("Not valid JSON: \(problem.description).", systemImage: StatusStyle.warningSymbol)
                .foregroundStyle(StatusStyle.warning)
                .font(.callout)
                .accessibilityLabel("Error: Not valid JSON: \(problem.description).")
        }
        if let fileError = editor.fileError {
            Label(fileError, systemImage: StatusStyle.errorSymbol)
                .foregroundStyle(StatusStyle.error)
                .font(.callout)
                .accessibilityLabel("Error: \(fileError)")
        }
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if editor.isEditable {
                Button("Open File…", action: openFile)
                    .keyboardShortcut("o")
                    .help("Load a file into this value")
            }
            Button("Save to File…", action: saveFile)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Write this value to a file")
            Spacer()
            if editor.isEditable {
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { editor.save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.canSave)
                    .help("Save this value (⌘Return)")
            } else {
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to load into \(editor.fieldName)."
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            editor.load(from: url)
        }
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = editor.suggestedFileName
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            editor.write(to: url)
        }
    }
}
