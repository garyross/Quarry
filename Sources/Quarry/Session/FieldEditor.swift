import AppKit
import Observation
import QuarryKit

/// The Field Editor sheet's state (S-012): one value, shown as Text, Image or
/// Hex, edited as text or replaced by a file.
@Observable
final class FieldEditor: Identifiable {
    enum Mode: String, CaseIterable, Identifiable {
        case text = "Text", image = "Image", hex = "Hex"
        var id: Self { self }
    }

    let id = UUID()
    /// The field's name, its type ("json", "blob"), and where the value is.
    let fieldName: String
    let fieldType: String?
    let row: Int
    let column: Int
    let original: CellValue
    /// False for views and Query results: Close and Save to File… only.
    let isEditable: Bool
    /// A JSON field, or text that is a JSON object or array: shown pretty-printed, checked before Save.
    let isJSON: Bool
    var mode: Mode
    /// What Text mode shows. Typing replaces bytes loaded from a file or the cell.
    var text: String {
        didSet { if text != oldValue, bytes != nil { bytes = nil } }
    }
    /// The value when it is bytes: a binary cell, or a file from Open File…
    private(set) var bytes: Data? {
        didSet { image = bytes.flatMap { $0.isEmpty ? nil : NSImage(data: $0) } }
    }
    /// The bytes as a picture, for Image mode; nil when they are not one.
    private(set) var image: NSImage?
    /// Why Open File… or Save to File… failed.
    var fileError: String?
    /// The text Text mode started with, so an untouched JSON value saves nothing.
    private let startText: String
    private let onSave: (FieldEditor, CellValue) -> Void

    init(fieldName: String, fieldType: String?, row: Int, column: Int, value: CellValue, typed: String? = nil,
         isEditable: Bool, onSave: @escaping (FieldEditor, CellValue) -> Void) {
        self.fieldName = fieldName
        self.fieldType = fieldType
        self.row = row
        self.column = column
        original = value
        self.isEditable = isEditable
        self.onSave = onSave
        let typedValue = typed.map(CellValue.text)
        isJSON = LongValue.isJSON(typedValue ?? value, fieldType: fieldType)
        var start = value.plainText ?? ""
        var startBytes: Data?
        if case .binary(let data) = value {
            startBytes = data
            start = String(data: data, encoding: .utf8) ?? ""
        }
        if let typed { start = typed; startBytes = nil }
        if isJSON, startBytes == nil, JSONText.check(start) == nil { start = JSONText.pretty(start) }
        startText = start
        text = start
        bytes = startBytes
        image = startBytes.flatMap { $0.isEmpty ? nil : NSImage(data: $0) }
        mode = .text
        mode = preferredMode
    }

    /// Image for a picture, Hex for bytes that are not text, else Text.
    private var preferredMode: Mode {
        if image != nil { return .image }
        return isTextAvailable ? .text : .hex
    }

    /// The value as bytes: what Image and Hex show and Save to File… writes.
    var data: Data { bytes ?? Data(text.utf8) }

    /// Bytes that are not UTF-8 have no Text mode.
    var isTextAvailable: Bool { bytes.map { String(data: $0, encoding: .utf8) != nil } ?? true }

    /// The modes that fit the value: Text for text, Image for a picture, and always Hex.
    var modes: [Mode] {
        (isTextAvailable ? [.text] : []) + (image != nil ? [.image] : []) + [.hex]
    }

    var hexDump: String { HexDump.format(data) }

    /// What Save writes: bytes, NULL kept when nothing was typed, or the text
    /// (JSON in the form it came in: compact stays compact).
    var value: CellValue {
        if let bytes { return bytes == original.binaryData ? original : .binary(bytes) }
        if original.isNull, text.isEmpty { return .null }
        if text == startText { return original }
        if isJSON, case .text(let old) = original, JSONText.isCompact(old) { return .text(JSONText.compact(text)) }
        return .text(text)
    }

    /// Why the JSON in Text mode cannot be saved; nil when it can.
    var jsonProblem: JSONText.Problem? {
        guard isJSON, bytes == nil, !(original.isNull && text.isEmpty) else { return nil }
        return JSONText.check(text)
    }

    var hasChanges: Bool { value != original }
    var canSave: Bool { isEditable && hasChanges && jsonProblem == nil }

    /// "attributes · json · 33 bytes", or "· NULL".
    var summary: String {
        var parts = [fieldName]
        if let fieldType, !fieldType.isEmpty { parts.append(fieldType) }
        parts.append(value.isNull ? "NULL" : ByteCount.format(data.count))
        return parts.joined(separator: " · ")
    }

    func save() {
        guard canSave else { return }
        onSave(self, value)
    }

    /// Open File…: text for a UTF-8 file in a text field, bytes otherwise.
    func load(from url: URL) {
        do {
            let file = try Data(contentsOf: url)
            fileError = nil
            let isTextField = !(fieldType.map { $0.lowercased().contains("blob") || $0.lowercased().contains("binary") } ?? false)
                && original.binaryData == nil
            if isTextField, let string = String(data: file, encoding: .utf8) {
                text = string
            } else {
                text = String(data: file, encoding: .utf8) ?? ""
                bytes = file
            }
            mode = preferredMode
        } catch {
            fileError = "Couldn't open “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    /// Save to File…: the value's bytes, text as UTF-8.
    func write(to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            fileError = nil
        } catch {
            fileError = "Couldn't save “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    /// A file name for Save to File…: the field's name with an extension that fits.
    var suggestedFileName: String {
        let ext: String
        if image != nil { ext = imageExtension }
        else if isJSON { ext = "json" }
        else if bytes != nil, !isTextAvailable { ext = "bin" }
        else { ext = "txt" }
        return fieldName + "." + ext
    }

    private var imageExtension: String {
        let header = [UInt8](data.prefix(4))
        switch header {
        case [0x89, 0x50, 0x4E, 0x47]: return "png"
        case _ where header.starts(with: [0xFF, 0xD8]): return "jpg"
        case [0x47, 0x49, 0x46, 0x38]: return "gif"
        default: return "tiff"
        }
    }
}

extension CellValue {
    /// The bytes of a binary value; nil for anything else.
    var binaryData: Data? {
        if case .binary(let data) = self { data } else { nil }
    }
}
