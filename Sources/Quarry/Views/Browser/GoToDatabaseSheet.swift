import QuarryKit
import SwiftUI

/// Go to Database (S-020), as Sequel Pro's: a search field over the server's
/// databases. Typed letters match in order ("qdm" finds quarry_demo), a search
/// in quotes matches as typed; the matched letters are bold. ↑ ↓ move the
/// selection from the field, Return or a double-click opens it, Escape cancels.
struct GoToDatabaseSheet: View {
    @Bindable var finder: DatabaseFinder
    let open: () -> Void
    let close: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Go to Database")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            TextField("Search", text: $finder.search, prompt: Text("Database name"))
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { open() }
                .onKeyPress(.downArrow) { finder.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { finder.moveSelection(by: -1); return .handled }
                .help("Type letters of the name in order; put the search in quotes to match it as typed")
                .accessibilityLabel("Search databases")
            list
                .frame(height: Layout.goToDatabaseListHeight)
                .gridProbe("list", area: "go-to-database")
            buttons
                .gridProbe("buttons", area: "go-to-database")
        }
        .padding(Space.margin)
        .frame(width: Layout.goToDatabaseWidth)
        .gridArea("go-to-database")
        .onAppear { searchFocused = true }
    }

    @ViewBuilder private var list: some View {
        if finder.matches.isEmpty {
            ContentUnavailableView.search(text: finder.search)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background, in: .rect(cornerRadius: Radius.sm))
        } else {
            ScrollViewReader { proxy in
                List(finder.matches, id: \.name, selection: $finder.selection) { match in
                    row(match)
                }
                .contextMenu(forSelectionType: String.self) { _ in
                } primaryAction: { _ in open() }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
                .onChange(of: finder.selection) { _, name in
                    if let name { proxy.scrollTo(name) }
                }
            }
        }
    }

    private func row(_ match: DatabaseMatch) -> some View {
        HStack(spacing: Space.sm) {
            Label {
                Text(highlighted(match))
            } icon: {
                Image(systemName: "cylinder.split.1x2")
            }
            Spacer(minLength: Space.sm)
            if match.name == finder.current {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Current database")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The name with its matched letters bold.
    private func highlighted(_ match: DatabaseMatch) -> AttributedString {
        var text = AttributedString(match.name)
        for range in match.ranges {
            if let found = Range(range, in: text) {
                text[found].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return text
    }

    private var buttons: some View {
        HStack(spacing: Space.sm) {
            Text(countText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Button("Open", action: open)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!finder.canOpen)
                .help("Open the selected database (Return)")
        }
    }

    private var countText: String {
        let total = finder.databases.count
        guard !finder.search.isEmpty else { return total == 1 ? "1 database" : "\(total) databases" }
        return "\(finder.matches.count) of \(total)"
    }
}
