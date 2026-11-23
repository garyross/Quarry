import AppKit
import SwiftUI

/// Plain multi-line text for values (the Field Editor, S-012): the editor's
/// monospaced font, no smart quotes or dashes, the find bar, and system
/// scroll bars. SwiftUI's TextEditor cannot turn substitutions off.
struct TextArea: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    /// Takes keyboard focus once, with the insertion point at the start.
    var focusesOnAppear = false
    /// False keeps each line whole and scrolls sideways (the Hex dump).
    var wraps = true
    var accessibilityLabel = "Value"

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.font = DataStyle.editorNSFont
        view.textColor = .labelColor
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = NSSize(width: 4, height: 8)
        view.delegate = context.coordinator
        view.setAccessibilityLabel(accessibilityLabel)
        if !wraps {
            scroll.hasHorizontalScroller = true
            view.isHorizontallyResizable = true
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        view.string = text
        view.isEditable = isEditable
        view.isSelectable = true
        if focusesOnAppear {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        if view.string != text {
            view.string = text
            view.scroll(.zero)
        }
        view.isEditable = isEditable
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
