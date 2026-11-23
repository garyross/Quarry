import QuarryKit
import SwiftUI

/// Connection Lost (S-050), Sequel Pro's ConnectionErrorDialog: the server went
/// away or closed the connection. Reconnect (Return) opens a new connection to
/// the same database, table and view; Close Connection returns to the Connect page.
struct ConnectionLostSheet: View {
    @Bindable var session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "network.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Connection Lost")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(session.lostConnectionText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let problem = session.reconnectProblem {
                        ErrorMessage(error: DatabaseError(message: "Could not reconnect: \(problem.message)",
                                                          suggestion: problem.suggestion))
                            .font(.callout)
                            .padding(.top, Space.xs)
                    }
                }
            }
            .gridProbe("message", area: "connection-lost")
            HStack(spacing: Space.sm) {
                if session.isReconnecting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Reconnecting")
                    Text("Reconnecting…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close Connection") { session.closeLostConnection() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(session.isReconnecting)
                    .help("Go back to the Connect page (Escape)")
                Button("Reconnect") { session.reconnect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isReconnecting)
                    .help("Connect again and return to the same database and table (Return)")
            }
            .gridProbe("buttons", area: "connection-lost")
        }
        .padding(Space.margin)
        .frame(width: Layout.connectionLostWidth)
        .gridArea("connection-lost")
        .noInitialFocus()
    }
}
