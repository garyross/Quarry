import Foundation
import Observation
import QuarryKit

/// The Bit Editor sheet's state (S-013): one BIT value, edited as bits or
/// typed in hexadecimal, decimal or octal. Save writes its bytes as an inline edit would.
@Observable
package final class BitEditor: Identifiable {
    /// The three typed forms of the value.
    package enum Base: String, CaseIterable, Identifiable {
        case hexadecimal = "Hexadecimal", decimal = "Decimal", octal = "Octal"
        package var id: Self { self }
        package var radix: Int { switch self { case .hexadecimal: 16; case .decimal: 10; case .octal: 8 } }
    }

    package let id = UUID()
    package let fieldName: String
    package let width: Int
    package let row: Int
    package let column: Int
    package let original: CellValue
    /// False for views and Query results: Close only.
    package let isEditable: Bool
    /// The field allows NULL, so the NULL checkbox shows.
    package let isNullable: Bool

    package private(set) var bits: BitValue
    package var isNull: Bool {
        didSet { if !isNull { refreshTexts() } }
    }
    /// What each text field shows; a field being typed in keeps its text until it reads as a number.
    package private(set) var texts: [Base: String] = [:]
    /// Fields whose text is not a number that fits, with why.
    package private(set) var problems: [Base: String] = [:]
    private let onSave: (CellValue) -> Void

    package init(fieldName: String, width: Int, row: Int, column: Int, value: CellValue, isEditable: Bool,
         isNullable: Bool, onSave: @escaping (CellValue) -> Void) {
        self.fieldName = fieldName
        self.row = row
        self.column = column
        original = value
        self.isEditable = isEditable
        self.isNullable = isNullable || value.isNull
        self.onSave = onSave
        let start = BitValue(width: width, value: value)
        bits = start
        self.width = start.width
        isNull = value.isNull
        refreshTexts()
    }

    // MARK: Changes

    package func bit(_ index: Int) -> Bool { bits.bit(index) }

    package func toggle(_ index: Int) { change { $0.toggle(index) } }
    package func setAll() { change { $0.setAll() } }
    package func clearAll() { change { $0.clearAll() } }
    package func invert() { change { $0.invert() } }
    package func shiftLeft() { change { $0.shiftLeft() } }
    package func shiftRight() { change { $0.shiftRight() } }
    package func rotateLeft() { change { $0.rotateLeft() } }
    package func rotateRight() { change { $0.rotateRight() } }

    /// Typing in one base: a number that fits updates the bits and the other fields.
    package func type(_ text: String, in base: Base) {
        texts[base] = text
        guard let value = bits.parse(text, radix: base.radix) else {
            problems[base] = text.isEmpty ? "Type a number." : "Not a \(base.rawValue.lowercased()) number from 0 to \(maximumText(base))."
            return
        }
        problems[base] = nil
        bits.set(value)
        isNull = false
        refreshTexts(except: base)
    }

    /// Return or leaving a field: it shows the value again in its usual spelling.
    package func tidy(_ base: Base) {
        texts[base] = text(of: bits, in: base)
        problems[base] = nil
    }

    package func text(_ base: Base) -> String { texts[base] ?? "" }

    private func change(_ body: (inout BitValue) -> Void) {
        body(&bits)
        isNull = false
        refreshTexts()
    }

    private func refreshTexts(except kept: Base? = nil) {
        for base in Base.allCases where base != kept {
            texts[base] = text(of: bits, in: base)
            problems[base] = nil
        }
    }

    private func text(of value: BitValue, in base: Base) -> String {
        switch base {
        case .hexadecimal: value.hex
        case .decimal: value.decimal
        case .octal: value.octal
        }
    }

    private func maximumText(_ base: Base) -> String {
        text(of: BitValue(width: width, raw: bits.maximum), in: base)
    }

    // MARK: Save

    /// NULL, or the bytes for the bits; the original when nothing changed.
    package var value: CellValue {
        if isNull { return .null }
        if !original.isNull, BitValue(width: width, value: original) == bits { return original }
        return .binary(bits.data)
    }

    package var hasChanges: Bool { value != original }
    package var canSave: Bool { isEditable && hasChanges && problems.isEmpty }

    /// "flags · bit(8)" or "flags · bit(8) · NULL".
    package var summary: String {
        "\(fieldName) · bit(\(width))" + (isNull ? " · NULL" : "")
    }

    package func save() {
        guard canSave else { return }
        onSave(value)
    }
}
