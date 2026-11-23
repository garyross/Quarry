# Quarry design system

Quarry keeps Apple's look. Tokens cover only what the system does not. Use
them in every view; never raw colors, radii, fonts, or durations. The plan
behind them is in `docs/DESIGN.md`.

## Theme (`UI/Theme.swift`)

- The accent follows the Mac (`ThemeStore.defaultID = "system"`). Quarry's
  brand, a deep teal (`0x0E7C7B`), shows while the Mac's accent is
  Multicolor. People can also pick "Quarry Teal" or any other accent in
  Settings > Appearance.
- Use `.tint` or `Palette.accent` for fills, `Palette.accentText` for
  accent-colored text, and `Palette.onAccent` for text on an accent fill.
  Never a hex in a view.
- Keep brand color rare: the icon, the Connect page's empty state, and the
  selection. Data, SQL and chrome stay neutral.
- Every custom color has light, dark, and both high-contrast values
  (`Color(light:dark:highContrastLight:highContrastDark:)`).

## Space (`UI/Grid.swift`)

- 4 pt grid: `xs 4`, `sm 8`, `md 12`, `lg 16`, `xl 20`, `xxl 24`, `section 32`,
  `margin 20`. Related controls get `sm`, groups get `xl`, and windows get `margin`.
- The grid and editor use AppKit row heights and insets. Only SwiftUI
  chrome around them uses `Space`.
- Dense areas use `.controlSize(.small)` (the status bar, the filter bar),
  never hard-coded heights.

## DataStyle (`UI/DataStyle.swift`)

- Values and SQL use SF Mono: grid `DataStyle.gridSize` (12), editor
  `DataStyle.editorSize` (13). Chrome uses the system font.
- NULL is the word `DataStyle.nullText` in `nullColor` (tertiary). An empty
  string is an empty cell. The two never look alike.
- Values that are not loaded (BLOB, long TEXT) show a placeholder such as
  "BLOB 12 KB" in `placeholderColor`.
- Editor colors come from `DataStyle.Syntax`. They are all system colors, so
  dark mode and Increase Contrast work without extra values. The statement
  ⌘R would run gets `Syntax.currentStatement`.

## StatusStyle (`UI/DataStyle.swift`)

- Errors, warnings, and success each pair a color with a symbol:
  `errorSymbol` + `error`, and so on. Never color alone.
- Server error text is shown verbatim and selectable, next to the problem
  (under the Connect form, in the Query error bar), never in an alert unless
  the person must act now (lost connection).
- Primary key fields show `primaryKeySymbol`, indexed fields `indexSymbol`.

## Motion (`UI/Motion.swift`)

- Almost nothing moves. View switches, the sidebar filter, query results,
  sorting, and paging are instant.
- `Motion.hover` for hover fills; `Motion.dim` for dimming stale content.
- Wait `Motion.loadingDelay` (0.5 s) before any spinner or dim. Faster loads
  show nothing.
- Animate through `Motion.run(_:reduceMotion:)`, so Reduce Motion turns it off.

## Layout and Radius (`UI/Layout.swift`)

- `Layout.connectFormWidth` (520) for the Connect form; sidebar
  `sidebarMin/Ideal/Max`; `detailMin` keeps the six view segments visible.
- Grid columns start between `gridColumnMin` and `gridColumnMax`, sized to
  their header and the first page of values.
- `Radius.xs` for chips, `sm` for controls and the error bar, `md` for cards.
  Inner corners are concentric.

## Components

- System controls only: `Picker(.segmented)`, `Form(.grouped)`, `List`
  (`.sidebar`), `Menu`, `.sheet`, `ContentUnavailableView`, and
  `.borderedProminent` for the one primary button (Connect).
- The two AppKit views (the data grid as `NSTableView`, the SQL editor as
  `NSTextView`) are wrapped in `NSViewRepresentable` and read `DataStyle`.
  docs/DESIGN.md §7 says why.
- `TileButtonStyle` (`UI/Components.swift`): the large tool buttons in the
  Database Information panel only. `isRisky` adds the warning mark for
  tools that change data; those always confirm first.
- Style a control with `ButtonStyle` / `ToggleStyle`. Never rebuild one from
  shapes.
