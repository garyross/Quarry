import SwiftUI

/// Approve Agent Change (S-064): an agent's write_query or kill_process, shown
/// on a window of its connection before it runs. Allow, Deny, or no answer in
/// time, which denies.
struct ApprovalSheet: View {
    let approval: AgentApproval

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "exclamationmark.shield")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Approve Agent Change")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(approval.client) wants to run this on \(approval.connection). Allow it only if you expect this change.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .gridProbe("message", area: "approval")
            Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: Space.xs) {
                row("Agent", approval.client)
                row("Token", approval.token)
                row("Connection", approval.connection)
                if let database = approval.database { row("Database", database) }
            }
            ScrollView {
                Text(approval.statement)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.sm)
            }
            .frame(height: Layout.approvalStatementHeight)
            .background(.background.secondary, in: .rect(cornerRadius: Radius.sm))
            .accessibilityLabel("Statement: \(approval.statement)")
            .gridProbe("statement", area: "approval")
            HStack(spacing: Space.sm) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Denies in " + Self.remaining(approval.deadline.timeIntervalSince(context.date)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("Deny") { approval.answer(false) }
                    .keyboardShortcut(.cancelAction)
                    .help("Don’t run it; the agent hears the change was denied (Escape)")
                Button("Allow") { approval.answer(true) }
                    .keyboardShortcut(.defaultAction)
                    .help("Run the statement on the agent’s own connection (Return)")
            }
            .gridProbe("buttons", area: "approval")
        }
        .padding(Space.margin)
        .frame(width: Layout.approvalSheetWidth)
        .gridArea("approval")
        .noInitialFocus()
        // Closed some other way (the window closing): that is Deny.
        .onDisappear { approval.answer(false) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    /// "1:45".
    static func remaining(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}
