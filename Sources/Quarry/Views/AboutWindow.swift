import AppKit
import SwiftUI

/// Quarry > About Quarry (S-057): the icon, name and version on the left;
/// what Quarry is, thanks, credit and the licenses on the right.
struct AboutWindow: View {
    static let sceneID = "about"
    static let summary = "A native Mac client for MySQL, MariaDB, and SQLite with MCP support."
    static let thanks = "Thank you to the makers of Sequel Pro."
    static let authorURL = URL(string: "https://www.linkedin.com/in/gary-ross/")!

    @State private var showsAcknowledgements = false

    var body: some View {
        HStack(alignment: .center, spacing: Space.section) {
            VStack(spacing: Space.sm) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: Layout.aboutIconSize, height: Layout.aboutIconSize)
                    .accessibilityHidden(true)
                Text("Quarry")
                    .font(.largeTitle)
                Text(Self.versionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(width: Layout.aboutSideWidth)
            VStack(alignment: .leading, spacing: Space.lg) {
                Text(Self.summary)
                    .font(.title3)
                Text(Self.thanks)
                    .font(.title3)
                HStack(spacing: 0) {
                    Link("Gary Ross", destination: Self.authorURL)
                        .help(Self.authorURL.absoluteString)
                    Text(", Kanazawa, Japan, 2026")
                        .foregroundStyle(.secondary)
                }
                Button("Acknowledgements") { showsAcknowledgements = true }
                    .help("The licenses of Sequel Pro and the packages Quarry is built with")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: Layout.aboutTextWidth, alignment: .leading)
        }
        .padding(Space.section)
        .gridArea("about")
        .noInitialFocus()
        .sheet(isPresented: $showsAcknowledgements) {
            AcknowledgementsSheet(close: { showsAcknowledgements = false })
        }
    }

    /// "Version 0.1 (202611191830)" from the bundle.
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        return "Version \(version) (\(build))"
    }

    /// The text tools/acknowledgements.sh writes into the app's Resources.
    static var acknowledgements: String {
        Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "No acknowledgements are bundled with this build."
    }
}

private struct AcknowledgementsSheet: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Acknowledgements")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(Space.margin)
            Divider()
            ScrollView {
                Text(AboutWindow.acknowledgements)
                    .font(DataStyle.gridFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.margin)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(Space.margin)
        }
        .frame(width: Layout.acknowledgementsWidth, height: Layout.acknowledgementsHeight)
    }
}
