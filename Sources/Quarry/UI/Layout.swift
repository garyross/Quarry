import SwiftUI

/// Fixed widths. Everything else sizes to content.
enum Layout {
    /// The Connect form, centered in the detail column.
    static let connectFormWidth: CGFloat = 520
    /// Sidebar column.
    static let sidebarMin: CGFloat = 200
    static let sidebarIdeal: CGFloat = 240
    static let sidebarMax: CGFloat = 360
    /// The detail column's minimum, so the toolbar's six view segments fit.
    static let detailMin: CGFloat = 640
    /// A grid column never starts narrower or wider than this.
    static let gridColumnMin: CGFloat = 48
    static let gridColumnMax: CGFloat = 360
    /// The Database Information panel: a fixed column, not SwiftUI's
    /// `.inspector`, which looped on its sizes and crashed (docs/FIXLOG.md).
    static let databaseInfoWidth: CGFloat = 340
    /// A tool button in that panel.
    static let tileHeight: CGFloat = 72
    /// Every tile's symbol gets the same box, so the titles line up.
    static let tileIconHeight: CGFloat = 28
    /// The Field Editor sheet's smallest size (S-012); people can make it larger.
    static let fieldEditorMinWidth: CGFloat = 640
    static let fieldEditorMinHeight: CGFloat = 320
    /// One bit in the Bit Editor: fits "0" or "1" with room to click.
    static let bitToggleWidth: CGFloat = 16
    /// The New Database sheet (S-018): room for "Server Default (utf8mb4_uca1400_ai_ci)".
    static let newDatabaseWidth: CGFloat = 480
    /// The Go to Database sheet (S-020) and its list: about ten names.
    static let goToDatabaseWidth: CGFloat = 400
    /// The Connection Lost sheet (S-050).
    static let connectionLostWidth: CGFloat = 420
    /// The SSH Trust Host and password sheets (S-047).
    static let sshQuestionWidth: CGFloat = 440
    /// The Add Field and Edit Field sheet (S-023).
    static let fieldSheetWidth: CGFloat = 520
    /// The Add Index sheet (S-024) and its Prefix fields (four digits).
    static let indexSheetWidth: CGFloat = 520
    static let prefixFieldWidth: CGFloat = 80
    /// Settings > MCP's Port field (S-063).
    static let portField: CGFloat = 80
    /// Settings > MCP > Manual Setup… (S-066)
    static let manualSetupWidth: CGFloat = 560
    static let manualSetupMaxHeight: CGFloat = 720
    /// Settings > MCP's token sheet (S-064); its form scrolls past about ten connections.
    static let tokenSheetWidth: CGFloat = 480
    static let tokenFormMaxHeight: CGFloat = 440
    /// Approve Agent Change (S-064) and its statement: about six lines.
    static let approvalSheetWidth: CGFloat = 520
    static let approvalStatementHeight: CGFloat = 120
    /// The Add Trigger and Edit Trigger sheet (S-026) and its statement editor: about ten lines.
    static let triggerSheetWidth: CGFloat = 560
    static let triggerEditorHeight: CGFloat = 200
    /// The New View, Procedure and Function sheet (S-030) and its editor: about twelve lines.
    static let definitionSheetWidth: CGFloat = 600
    static let definitionEditorHeight: CGFloat = 240
    /// A function's form (seven rows and the editor) runs past the usual 640 cap.
    static let definitionSheetMaxHeight: CGFloat = 760
    static let goToDatabaseListHeight: CGFloat = 240
    /// The Save Query sheet's preview: about six lines (S-034).
    static let saveQueryPreviewHeight: CGFloat = 120
    /// The Saved Queries window (S-034): its list column and its smallest size.
    static let savedQueriesListWidth: CGFloat = 220
    static let savedQueriesMinWidth: CGFloat = 640
    static let savedQueriesMinHeight: CGFloat = 360
    /// The Console window (S-039): its smallest size and its columns.
    static let consoleMinWidth: CGFloat = 560
    static let consoleMinHeight: CGFloat = 240
    static let consoleTimeWidth: CGFloat = 80
    static let consoleNameWidth: CGFloat = 120
    static let consoleNameMin: CGFloat = 60
    static let consoleNameMax: CGFloat = 160
    static let consoleQueryMin: CGFloat = 200
    /// MCP Activity (S-065): its smallest size and its columns.
    static let activityMinWidth: CGFloat = 760
    static let activityMinHeight: CGFloat = 280
    static let activityTimeWidth: CGFloat = 116
    static let activityNameWidth: CGFloat = 108
    static let activityTokenWidth: CGFloat = 84
    static let activityPlaceWidth: CGFloat = 136
    static let activityShortWidth: CGFloat = 64
    static let activityStatementMin: CGFloat = 160
    /// Help > Keyboard Shortcuts (S-040).
    static let shortcutsMinWidth: CGFloat = 400
    static let shortcutsMinHeight: CGFloat = 320
}

/// Corner radii. Inner corners are concentric: inner = outer - inset.
enum Radius {
    /// Chips, key caps, the connection color dot's ring.
    static let xs: CGFloat = 6
    /// Controls and the error bar.
    static let sm: CGFloat = 8
    /// Cards (the Connect form group).
    static let md: CGFloat = 12
}

extension Layout {
    /// The Show Create Statement sheet (S-028): about 80 columns by 24 lines of SQL to start.
    static let createStatementMinWidth: CGFloat = 640
    static let createStatementMinHeight: CGFloat = 360
}

extension Layout {
    /// The Export sheet (S-041): room for the object list's four columns and the options.
    static let exportSheetWidth: CGFloat = 560
    /// About ten objects before the list scrolls.
    static let exportListHeight: CGFloat = 240
    /// The Structure, Content and Drop checkbox columns.
    static let exportCheckColumn: CGFloat = 72
    static let exportBatchField: CGFloat = 72
    /// The Import sheet (S-044): a file name, two pickers, and a failed statement.
    static let importSheetWidth: CGFloat = 520
    /// Lines of clipboard text the Import sheet previews (S-046).
    static let clipboardPreviewLines = 7
    /// The finished import's error list, before it scrolls.
    static let importErrorsHeight: CGFloat = 120
    /// The Export sheet's Source popup (S-042): long table names truncate inside it.
    static let exportSourceWidth: CGFloat = 280
}

extension Layout {
    /// The CSV field mapping (S-045): a field, its column popup, Match, and the previewed value.
    static let csvMappingWidth: CGFloat = 720
    /// About eight fields before the grid scrolls.
    static let csvMappingGridHeight: CGFloat = 240
    static let csvColumnPopupWidth: CGFloat = 200
    static let csvMatchColumn: CGFloat = 48
}

extension Layout {
    /// The User Accounts sheet (S-051): the account list and the tabs, whose
    /// Global Privileges show three checkbox columns.
    static let userAccountsWidth: CGFloat = 800
    static let userAccountsHeight: CGFloat = 520
    static let userAccountsListWidth: CGFloat = 200
    /// Schema Privileges' database list.
    static let schemaListWidth: CGFloat = 200
    /// Resources' number fields.
    static let limitFieldWidth: CGFloat = 96
}

extension Layout {
    /// The Server Variables sheet (S-052): about fifteen rows of a name and a value.
    static let variablesWidth: CGFloat = 640
    static let variablesTableHeight: CGFloat = 400
    static let variablesFilterWidth: CGFloat = 220
    static let variablesNameMin: CGFloat = 160
    static let variablesNameWidth: CGFloat = 260
}

extension Layout {
    /// The Server Processes window (S-053) and its columns.
    static let processesMinWidth: CGFloat = 720
    static let processesMinHeight: CGFloat = 240
    static let processesIDWidth: CGFloat = 56
    static let processesTimeWidth: CGFloat = 56
    static let processesNameMin: CGFloat = 48
    static let processesNameWidth: CGFloat = 100
    static let processesCommandWidth: CGFloat = 72
}

extension Layout {
    /// Server Processes' Info column: whatever room is left, never less than this.
    static let processesInfoMin: CGFloat = 120
}

extension Layout {
    /// The Save Connection File and Save Session sheet (S-055).
    static let connectionFileWidth: CGFloat = 480
}

extension Layout {
    /// About Quarry (S-057) and its Acknowledgements sheet.
    static let aboutSideWidth: CGFloat = 200
    static let aboutTextWidth: CGFloat = 300
    static let aboutIconSize: CGFloat = 128
    static let acknowledgementsWidth: CGFloat = 600
    static let acknowledgementsHeight: CGFloat = 480
}
