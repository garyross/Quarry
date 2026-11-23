import AppKit
import QuarryKit
import SwiftUI

/// The Query view's SQL editor.
///
/// AppKit's NSTextView, not SwiftUI's TextEditor: the editor needs syntax
/// colors, line numbers, and a highlight on the statement ⌘R would run
/// (docs/DESIGN.md §7). It uses TextKit 1 for the layout manager's temporary
/// attributes, which color text without touching the undo stack.
struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursor: Int
    @Binding var selectRequest: NSRange?
    var errorLine: Int?
    /// False skips the highlight on the statement ⌘R would run (a trigger's body is one statement).
    var marksStatement = true
    var accessibilityLabel = "SQL editor"
    /// The completion list at a position (S-031); nil turns completion off.
    /// The flag is true when the user asked for the list (⌥⎋ or Escape).
    var completions: ((String, Int, Bool) -> CompletionList?)?
    /// Set by Show Completions in the Query menu; the editor clears it.
    var completionRequest: Binding<Bool>?
    /// Changes when the catalog gains tables, so an open list refreshes.
    var completionRevision = 0
    /// Set by the Query menu's editing commands (S-032); the editor runs it and clears it.
    var editorCommand: Binding<EditorCommand?>?
    /// Text to put in place of the selection and select (query history, S-033); the editor clears it.
    var insertRequest: Binding<String?>?
    /// The Undo menu's name for `insertRequest` ("Insert Query from History", "Insert Saved Query").
    var insertActionName = "Insert Query from History"
    /// The selected range, reported as it changes (Save Query… saves a selection, S-034).
    var selection: Binding<NSRange>?

    /// Settings > General: Suggest completions while typing.
    static let autoCompleteKey = "query.autoComplete"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Apple's TextKit 1 setup: storage, layout manager and container first,
        // then a text view sized to the scroll view. A zero-size start leaves
        // the container negative-width and the text invisible.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let size = scroll.contentSize
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = SQLTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = DataStyle.editorNSFont
        textView.textColor = DataStyle.Syntax.plain
        textView.typingAttributes = [.font: DataStyle.editorNSFont, .foregroundColor: DataStyle.Syntax.plain]
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.string = text
        textView.setSelectedRange(NSRange(location: min(cursor, (text as NSString).length), length: 0))
        textView.delegate = context.coordinator

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.followWidth(of: scroll.contentView)
        context.coordinator.applyPreferences()
        context.coordinator.followPreferences()
        context.coordinator.highlight()
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.hideCompletions()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            coordinator.hideCompletions()
            textView.string = text
            coordinator.highlight()
            coordinator.ruler?.needsDisplay = true
        }
        if let request = selectRequest {
            let range = NSRange(location: min(request.location, (textView.string as NSString).length), length: 0)
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            DispatchQueue.main.async { selectRequest = nil }
        }
        if let request = completionRequest, request.wrappedValue {
            textView.window?.makeFirstResponder(textView)
            coordinator.updateCompletions(explicit: true)
            DispatchQueue.main.async { request.wrappedValue = false }
        }
        if let request = editorCommand, let command = request.wrappedValue {
            coordinator.hideCompletions()
            textView.window?.makeFirstResponder(textView)
            (textView as? SQLTextView)?.perform(command)
            DispatchQueue.main.async { request.wrappedValue = nil }
        }
        if let request = insertRequest, let insert = request.wrappedValue {
            coordinator.hideCompletions()
            textView.window?.makeFirstResponder(textView)
            (textView as? SQLTextView)?.replaceSelection(with: insert, actionName: insertActionName)
            DispatchQueue.main.async { request.wrappedValue = nil }
        }
        if coordinator.completionRevision != completionRevision {
            coordinator.completionRevision = completionRevision
            if coordinator.wantsCompletions { coordinator.updateCompletions(explicit: coordinator.lastWasExplicit) }
        }
        if coordinator.ruler?.errorLine != errorLine {
            coordinator.ruler?.errorLine = errorLine
            coordinator.ruler?.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditor
        weak var textView: NSTextView?
        weak var ruler: LineNumberRuler?
        private var currentStatement: NSRange?
        private lazy var popup: CompletionPopup = {
            let popup = CompletionPopup()
            popup.onAccept = { [weak self] item in self?.accept(item) }
            return popup
        }()
        /// The last edit typed a word character or a dot, so the list may open.
        private var typedWord = false
        /// A list is showing or was asked for and waits on the catalog.
        var wantsCompletions = false
        var lastWasExplicit = false
        var completionRevision = 0

        /// The font size and tab width last applied (S-054).
        private var appliedStyle: (size: CGFloat, tab: Int)?
        nonisolated(unsafe) private var preferencesObserver: NSObjectProtocol?

        init(_ parent: SQLEditor) {
            self.parent = parent
            self.completionRevision = parent.completionRevision
        }

        deinit {
            if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        }

        func followPreferences() {
            preferencesObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.applyPreferences() } }
        }

        /// Settings > Editor: the font size and how wide a tab is, applied to the text in place.
        func applyPreferences() {
            guard let textView else { return }
            let style = (size: DataStyle.editorSize, tab: Preferences.tabWidth)
            if let appliedStyle, appliedStyle == style { return }
            appliedStyle = style
            let font = DataStyle.editorNSFont
            let paragraph = NSMutableParagraphStyle()
            let space = (" " as NSString).size(withAttributes: [.font: font]).width
            paragraph.tabStops = []
            paragraph.defaultTabInterval = space * CGFloat(style.tab)
            textView.font = font
            textView.defaultParagraphStyle = paragraph
            textView.typingAttributes = [.font: font, .foregroundColor: DataStyle.Syntax.plain, .paragraphStyle: paragraph]
            if let storage = textView.textStorage {
                let all = NSRange(location: 0, length: storage.length)
                storage.addAttributes([.font: font, .paragraphStyle: paragraph], range: all)
            }
            ruler?.needsDisplay = true
        }

        /// Keeps the text view as wide as the visible area as the window resizes.
        func followWidth(of clip: NSClipView) {
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipResized(_:)),
                                                   name: NSView.frameDidChangeNotification, object: clip)
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }

        @objc private func clipScrolled(_ note: Notification) {
            hideCompletions()
        }

        @objc private func clipResized(_ note: Notification) {
            guard let clip = note.object as? NSClipView, let textView else { return }
            let width = clip.bounds.width
            if abs(textView.frame.width - width) > 0.5 {
                textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, clip.bounds.height)))
                textView.minSize = NSSize(width: 0, height: clip.bounds.height)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight()
            ruler?.needsDisplay = true
            let auto = UserDefaults.standard.object(forKey: SQLEditor.autoCompleteKey) as? Bool ?? true
            if typedWord, auto || popup.isShowing {
                updateCompletions(explicit: lastWasExplicit && popup.isShowing)
            } else {
                hideCompletions()
            }
            typedWord = false
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString else { return true }
            if replacement.isEmpty {
                // Delete narrows an open list; it does not open one.
                typedWord = popup.isShowing && range.length <= 1
            } else {
                let units = Array(replacement.utf16)
                // "``" is a backtick with its match (S-032); a name follows.
                typedWord = (units.count == 1 && (units[0] == 46 || units[0] == 96 || isWordUnit(units[0]))) || units == [96, 96]
            }
            return true
        }

        private func isWordUnit(_ unit: UInt16) -> Bool {
            (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit == 36 || unit > 127
        }

        func textDidEndEditing(_ notification: Notification) {
            hideCompletions()
        }

        /// While the list shows: ↑ ↓ Page Up Page Down move, Tab and Return accept, Escape closes.
        /// Escape and ⌥⎋ (complete:) open it when it is closed.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if popup.isShowing {
                switch selector {
                case #selector(NSResponder.moveUp(_:)): popup.move(by: -1); return true
                case #selector(NSResponder.moveDown(_:)): popup.move(by: 1); return true
                case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
                    popup.move(by: -CompletionPopup.visibleRows); return true
                case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
                    popup.move(by: CompletionPopup.visibleRows); return true
                case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
                    if let item = popup.selected { accept(item); return true }
                case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                    hideCompletions(); return true
                default:
                    hideCompletions()
                }
                return false
            }
            if parent.completions != nil,
               selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSTextView.complete(_:)) {
                updateCompletions(explicit: true)
                return true
            }
            return false
        }

        /// Opens, narrows or closes the list for the word at the cursor.
        func updateCompletions(explicit: Bool) {
            guard let textView, let completions = parent.completions,
                  let window = textView.window else { return hideCompletions() }
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return hideCompletions() }
            wantsCompletions = true
            lastWasExplicit = explicit
            guard let list = completions(textView.string, selection.location, explicit) else {
                // Still wanted if the catalog is loading; the revision brings it back.
                popup.hide()
                return
            }
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: list.replaceRange.location, length: 0),
                                           actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            if textView.string.isEmpty || rect.height == 0 {
                rect = layout.extraLineFragmentRect
            }
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            rect.size.width = max(rect.width, 1)
            popup.show(list, below: window.convertToScreen(textView.convert(rect, to: nil)), of: window)
        }

        func hideCompletions() {
            wantsCompletions = false
            popup.hide()
        }

        private func accept(_ item: Completion) {
            guard let textView, let list = popup.list else { return }
            hideCompletions()
            let range = list.replaceRange
            guard NSMaxRange(range) <= (textView.string as NSString).length else { return }
            var text = item.insertText
            // "SELECT " before an existing space would leave two.
            let ns = textView.string as NSString
            if text.hasSuffix(" "), NSMaxRange(range) < ns.length,
               let next = Unicode.Scalar(ns.character(at: NSMaxRange(range))),
               CharacterSet.whitespacesAndNewlines.contains(next) {
                text.removeLast()
            }
            textView.insertText(text, replacementRange: range)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let cursor = textView.selectedRange().location
            if parent.cursor != cursor {
                DispatchQueue.main.async { [parent] in parent.cursor = cursor }
            }
            let range = textView.selectedRange()
            if let selection = parent.selection, selection.wrappedValue != range {
                DispatchQueue.main.async { selection.wrappedValue = range }
            }
            // Moving away from the word closes the list.
            if let list = popup.list, popup.isShowing,
               textView.selectedRange().length > 0 || cursor < list.replaceRange.location
                || cursor > NSMaxRange(list.replaceRange) + 1 {
                hideCompletions()
            }
            highlightCurrentStatement()
        }

        /// Colors keywords, strings, numbers, comments, identifiers and variables.
        func highlight() {
            guard let textView, let layout = textView.layoutManager else { return }
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
            for token in SQLHighlighter.tokens(in: textView.string) {
                let color = SQLText.color(token.kind)
                layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
            }
            currentStatement = nil
            highlightCurrentStatement()
        }

        /// A light background behind the statement ⌘R would run.
        private func highlightCurrentStatement() {
            guard let textView, let layout = textView.layoutManager else { return }
            let statements = StatementSplitter.split(textView.string)
            // Whole lines, newline included, so the band is one even block (S-032).
            let range = parent.marksStatement && statements.count > 1
                ? StatementSplitter.statement(at: textView.selectedRange().location, in: statements)
                    .map { (textView.string as NSString).lineRange(for: $0.range) }
                : nil
            guard range != currentStatement else { return }
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
            if let range {
                layout.addTemporaryAttribute(.backgroundColor, value: DataStyle.Syntax.currentStatement, forCharacterRange: range)
            }
            currentStatement = range
        }
    }
}

/// Line numbers beside the editor. The error's line shows in the error color.
final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var errorLine: Int?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        // Since macOS 14 views draw outside their bounds unless told not to;
        // the ruler's background would paint over the text.
        clipsToBounds = true
        // Redraw the numbers when the text scrolls.
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        rect.intersection(bounds).fill()
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // Count the lines before the first visible character.
        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: characters.location),
                                 options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let inset = textView.textContainerInset.height
        var index = characters.location
        repeat {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: min(lineRange.location, max(0, text.length - 1)))
            var fragment = text.length == 0 ? .zero : layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if text.length == 0 { fragment.size.height = DataStyle.editorNSFont.boundingRectForFont.height }
            let y = fragment.minY + inset - visible.minY
            let color: NSColor = line == errorLine ? .systemRed : .tertiaryLabelColor
            let label = "\(line)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            line += 1
            index = NSMaxRange(lineRange)
        } while index < NSMaxRange(characters)
        // The empty last line after a trailing newline.
        if text.length > 0, text.hasSuffix("\n"), index >= text.length {
            let fragment = layout.extraLineFragmentRect
            let y = fragment.minY + inset - visible.minY
            let label = "\(line)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
        }
    }
}
