import AppKit
import QuarryKit

/// Self-test: Server Variables (S-052).
extension SelfTest {
    static func serverVariables(session: Session) async {
        await session.requestServerVariables()?.value
        guard let list = session.serverVariables else { return check("S-052 ⇧⌘V opens Server Variables", false) }
        check("S-052 the sheet lists SHOW VARIABLES",
              list.error == nil && list.variables.contains { $0.name == "version" } && list.countText.hasSuffix("variables"),
              list.error?.message ?? list.countText)
        list.search = "BUFFER"
        check("S-052 the filter matches names and values, ignoring case, and counts N of M",
              !list.shown.isEmpty && list.shown.allSatisfy { $0.name.contains("buffer") || $0.value.lowercased().contains("buffer") }
                  && list.countText == "\(list.shown.count) of \(list.variables.count)" && list.saveTitle == "Save View As…",
              list.countText)
        let two = Set(list.shown.prefix(2).map(\.id))
        list.selection = two
        list.copy(.name)
        let names = NSPasteboard.general.string(forType: .string) ?? ""
        list.copy(.both)
        let both = NSPasteboard.general.string(forType: .string) ?? ""
        check("S-052 Copy Variable Names and Copy put the selected rows on the clipboard",
              names.split(separator: "\n").count == 2 && both.contains(" = "), names + " | " + both)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quarry-selftest-variables.cnf")
        try? list.save(to: url)
        let saved = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check("S-052 Save View As… writes the variables shown as name = value lines",
              saved.hasPrefix("# Server variables for ") && saved.split(separator: "\n").count == list.shown.count + 1,
              String(saved.prefix(80)))
        try? FileManager.default.removeItem(at: url)
        session.serverVariables = nil
    }
}
