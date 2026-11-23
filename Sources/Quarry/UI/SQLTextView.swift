import AppKit
import QuarryKit

/// The Query menu's editor commands (S-032), sent to the editor through
/// `QueryController.editorCommand` or caught as key equivalents by `SQLTextView`.
enum EditorCommand: String, CaseIterable, Sendable {
    case selectStatement, commentLine, commentStatement, shiftRight, shiftLeft

    var title: String {
        switch self {
        case .selectStatement: "Select Current Statement"
        case .commentLine: "Comment Line"
        case .commentStatement: "Comment Current Statement"
        case .shiftRight: "Shift Right"
        case .shiftLeft: "Shift Left"
        }
    }

    /// The key and modifiers, as in Sequel Pro's Query gear menu and Edit > Select.
    var key: (character: String, modifiers: NSEvent.ModifierFlags) {
        switch self {
        case .selectStatement: ("y", [.control])
        case .commentLine: ("/", [.command])
        case .commentStatement: ("/", [.command, .option])
        case .shiftRight: ("]", [.command])
        case .shiftLeft: ("[", [.command])
        }
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let character = event.charactersIgnoringModifiers?.lowercased(),
              let match = Self.allCases.first(where: { $0.key.character == character && $0.key.modifiers == flags })
        else { return nil }
        self = match
    }
}

extension NSAttributedString.Key {
    /// Marks a closing bracket or quote the editor inserted, so typing it steps over it.
    static let sqlPairLinked = NSAttributedString.Key("app.quarry.sqlPairLinked")
}

/// The SQL editor's text view: matching brackets and quotes, uppercase
/// keywords, indented new lines, and the Query menu's editing commands. The
/// rules live in `SQLEditing`; this class applies them so Undo works.
final class SQLTextView: NSTextView {
    /// Settings > General > Query.
    static let autoPairKey = "query.autoPair"
    static let autoUppercaseKey = "query.autoUppercase"

    private var autoPair: Bool { UserDefaults.standard.object(forKey: Self.autoPairKey) as? Bool ?? true }
    private var autoUppercase: Bool { UserDefaults.standard.object(forKey: Self.autoUppercaseKey) as? Bool ?? true }

    // MARK: Typing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        let selection = selectedRange()
        guard let typed, typed.utf16.count == 1, !hasMarkedText(), isEditable,
              replacementRange.location == NSNotFound || replacementRange == selection else {
            return super.insertText(string, replacementRange: replacementRange)
        }
        if autoPair, case .skip(let caret)? = SQLEditing.pair(self.string, selection: selection, typed: typed,
                                                              nextIsLinked: isLinked(at: selection.location)) {
            setSelectedRange(caret)
            return
        }
        uppercaseKeyword(before: typed)
        let now = selectedRange()
        if autoPair, let action = SQLEditing.pair(self.string, selection: now, typed: typed, nextIsLinked: false) {
            switch action {
            case .skip: break
            case .wrap(let edit):
                apply(edit, actionName: nil)
                return
            case .insertPair(let edit, let linked):
                super.insertText(edit.replacement, replacementRange: edit.range)
                textStorage?.addAttribute(.sqlPairLinked, value: true, range: linked)
                setSelectedRange(edit.selection)
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Return keeps the line's indent.
    override func insertNewline(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return super.insertNewline(sender) }
        uppercaseKeyword(before: "\n")
        let selection = selectedRange()
        let indent = SQLEditing.indentation(string, at: selection.location)
        super.insertText("\n" + indent, replacementRange: selection)
    }

    /// Delete inside an empty pair the editor made, `(|)`, removes both halves.
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if autoPair, selection.length == 0,
           let pair = SQLEditing.deletesPair(string, caret: selection.location, nextIsLinked: isLinked(at: selection.location)) {
            setSelectedRange(pair)
        }
        super.deleteBackward(sender)
    }

    /// New text never inherits the linked mark from the character before it.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            var attributes = newValue
            attributes.removeValue(forKey: .sqlPairLinked)
            super.typingAttributes = attributes
        }
    }

    private func isLinked(at location: Int) -> Bool {
        guard let storage = textStorage, location < storage.length else { return false }
        return storage.attribute(.sqlPairLinked, at: location, effectiveRange: nil) != nil
    }

    private func uppercaseKeyword(before typed: String) {
        let selection = selectedRange()
        guard autoUppercase, selection.length == 0,
              let edit = SQLEditing.uppercaseKeyword(string, before: selection.location, typed: typed),
              shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
    }

    // MARK: Commands

    /// ⌘/ ⌥⌘/ ⌘] ⌘[ ⌃Y while the editor has focus, also in sheets where the
    /// Query menu is off. Back and Forward keep ⌘[ ⌘] everywhere else.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let command = EditorCommand(event: event) {
            perform(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Runs a command; Undo reverses it in one step.
    func perform(_ command: EditorCommand) {
        let text = string
        let selection = selectedRange()
        switch command {
        case .selectStatement:
            if let range = SQLEditing.currentStatement(text, at: selection.location) {
                setSelectedRange(range)
                scrollRangeToVisible(range)
            }
            return
        case .commentLine:
            if let edit = SQLEditing.toggleComment(text, selection: selection) { apply(edit, actionName: command.title) }
        case .commentStatement:
            if let edit = SQLEditing.toggleStatementComment(text, selection: selection) { apply(edit, actionName: command.title) }
        case .shiftRight:
            if let edit = SQLEditing.shiftRight(text, selection: selection) { apply(edit, actionName: command.title) }
        case .shiftLeft:
            if let edit = SQLEditing.shiftLeft(text, selection: selection) { apply(edit, actionName: command.title) }
        }
    }

    /// Puts `text` in place of the selection and selects it, as one Undo step.
    func replaceSelection(with text: String, actionName: String) {
        let range = selectedRange()
        let inserted = NSRange(location: range.location, length: (text as NSString).length)
        apply(TextEdit(range: range, replacement: text, selection: inserted), actionName: actionName)
    }

    /// Replaces text through the undo-aware path; a named action is its own Undo step.
    private func apply(_ edit: TextEdit, actionName: String?) {
        guard isEditable else { return }
        if actionName != nil { breakUndoCoalescing() }
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        if let actionName {
            undoManager?.setActionName(actionName)
            breakUndoCoalescing()
        }
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }
}
