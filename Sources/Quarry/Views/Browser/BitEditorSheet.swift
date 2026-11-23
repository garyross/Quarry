import QuarryKit
import QuarryControllers
import SwiftUI

/// The Bit Editor (S-013): a BIT value's bits as toggles, eight to a row,
/// most significant first, with the value in hexadecimal, decimal and octal.
/// Save (⌘Return) writes it as an inline edit would; Escape cancels.
struct BitEditorSheet: View {
    @Bindable var editor: BitEditor
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(editor.summary)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            bitRows
            operations
            numbers
            buttons
        }
        .padding(Space.margin)
        .fixedSize()
        .gridArea("bit-editor")
        .noInitialFocus()
    }

    /// Bits 63–56 on top down to 7–0, each row read left to right like b'…'.
    private var bitRows: some View {
        let rowCount = (editor.width + 7) / 8
        return Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: Space.sm) {
            ForEach((0..<rowCount).reversed(), id: \.self) { row in
                let low = row * 8
                let high = min(low + 7, editor.width - 1)
                GridRow {
                    Text(high == low ? "Bit \(low)" : "Bits \(high)–\(low)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                    HStack(spacing: Space.xs) {
                        // A short top row keeps its bits under the same columns as the rows below.
                        ForEach(0..<(7 - (high - low)), id: \.self) { _ in
                            Color.clear.frame(width: Layout.bitToggleWidth, height: 1)
                        }
                        ForEach((low...high).reversed(), id: \.self) { index in
                            bitToggle(index)
                            if index % 4 == 0, index != low { Spacer().frame(width: Space.sm) }
                        }
                    }
                }
            }
        }
        .disabled(editor.isNull)
        .gridProbe("bits", area: "bit-editor")
    }

    private func bitToggle(_ index: Int) -> some View {
        Toggle(isOn: Binding(get: { editor.bit(index) }, set: { _ in editor.toggle(index) })) {
            Text(editor.bit(index) ? "1" : "0")
                .font(.body.monospaced())
                .fontWeight(editor.bit(index) ? .semibold : .regular)
                .frame(width: Layout.bitToggleWidth)
        }
        .toggleStyle(.button)
        .disabled(!editor.isEditable)
        .help("Bit \(index)")
        .accessibilityLabel("Bit \(index)")
        .accessibilityValue(editor.bit(index) ? "1" : "0")
    }

    @ViewBuilder
    private var operations: some View {
        if editor.isEditable {
            HStack(spacing: Space.sm) {
                ControlGroup {
                    Button("Shift Left", systemImage: "arrow.left", action: editor.shiftLeft)
                        .keyboardShortcut("[")
                        .help("Move every bit left; the right bit becomes 0 (⌘[)")
                    Button("Shift Right", systemImage: "arrow.right", action: editor.shiftRight)
                        .keyboardShortcut("]")
                        .help("Move every bit right; the left bit becomes 0 (⌘])")
                }
                .fixedSize()
                ControlGroup {
                    Button("Rotate Left", systemImage: "arrow.uturn.left", action: editor.rotateLeft)
                        .keyboardShortcut("[", modifiers: [.command, .option])
                        .help("Move every bit left; the left bit comes back on the right (⌥⌘[)")
                    Button("Rotate Right", systemImage: "arrow.uturn.right", action: editor.rotateRight)
                        .keyboardShortcut("]", modifiers: [.command, .option])
                        .help("Move every bit right; the right bit comes back on the left (⌥⌘])")
                }
                .fixedSize()
                Spacer(minLength: Space.md)
                Button("All 0", action: editor.clearAll)
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                    .help("Set every bit to 0 (⇧⌘0)")
                Button("All 1", action: editor.setAll)
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                    .help("Set every bit to 1 (⇧⌘1)")
                Button("Invert", action: editor.invert)
                    .keyboardShortcut("i")
                    .help("Turn every 0 into 1 and every 1 into 0 (⌘I)")
            }
            .labelStyle(.iconOnly)
        }
    }

    private var numbers: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: Space.sm) {
            ForEach(BitEditor.Base.allCases) { base in
                GridRow {
                    Text(base.rawValue)
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        TextField(base.rawValue, text: Binding(get: { editor.text(base) },
                                                               set: { editor.type($0, in: base) }))
                            .labelsHidden()
                            .font(.body.monospaced())
                            .disabled(!editor.isEditable)
                            .onSubmit { editor.tidy(base) }
                            .help("The value in \(base.rawValue.lowercased()); typing changes the bits")
                        if let problem = editor.problems[base] {
                            Label(problem, systemImage: StatusStyle.warningSymbol)
                                .foregroundStyle(StatusStyle.warning)
                                .font(.callout)
                                .accessibilityLabel("Error: \(problem)")
                        }
                    }
                }
            }
        }
        .disabled(editor.isNull)
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            if editor.isNullable, editor.isEditable {
                Toggle("NULL", isOn: $editor.isNull)
                    .help("Save NULL instead of a number")
            }
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
}
