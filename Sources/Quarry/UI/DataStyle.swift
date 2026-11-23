import AppKit
import SwiftUI

/// How database values and SQL look. Grid and editor code reads these, never
/// raw fonts or colors. docs/DESIGN.md §6, design/DESIGN-SYSTEM.md "DataStyle".
enum DataStyle {
    /// Grid cells (Content, query results, Structure): SF Mono 12 pt unless
    /// Settings > Tables says otherwise (S-054).
    static var gridSize: CGFloat { CGFloat(Preferences.gridSize) }
    /// The SQL editor: SF Mono 13 pt unless Settings > Editor says otherwise.
    static var editorSize: CGFloat { CGFloat(Preferences.editorSize) }

    static var gridFont: Font { .system(size: gridSize, design: Preferences.monospaced ? .monospaced : .default) }
    static var gridNSFont: NSFont {
        Preferences.monospaced ? .monospacedSystemFont(ofSize: gridSize, weight: .regular) : .systemFont(ofSize: gridSize)
    }
    static var editorNSFont: NSFont { .monospacedSystemFont(ofSize: editorSize, weight: .regular) }

    /// NULL is drawn as this word, in tertiary text, never as an empty cell (Settings > Tables).
    static var nullText: String { Preferences.nullText }
    static var nullColor: NSColor { .tertiaryLabelColor }
    /// Values not loaded yet (BLOB/TEXT placeholders like "BLOB 12 KB").
    static var placeholderColor: NSColor { .secondaryLabelColor }

    /// Syntax colors for the SQL editor. System colors, so they adapt to dark
    /// mode and Increase Contrast on their own.
    enum Syntax {
        static var keyword: NSColor { .systemPink }
        static var string: NSColor { .systemRed }
        static var number: NSColor { .systemPurple }
        static var comment: NSColor { .secondaryLabelColor }
        static var identifier: NSColor { .systemTeal }
        static var variable: NSColor { .systemOrange }
        static var plain: NSColor { .labelColor }
        /// Background behind the statement ⌘R would run.
        static var currentStatement: NSColor { .controlAccentColor.withAlphaComponent(0.08) }
    }
}

/// Status that needs a color. Each one always comes with its symbol or a word.
enum StatusStyle {
    static let errorSymbol = "exclamationmark.octagon.fill"
    static let warningSymbol = "exclamationmark.triangle.fill"
    static let successSymbol = "checkmark.circle.fill"
    static var error: Color { .red }
    static var warning: Color { .orange }
    static var success: Color { .green }
    /// Key column markers in Structure.
    static let primaryKeySymbol = "key.fill"
    static let indexSymbol = "key"
}
