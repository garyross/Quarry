import QuarryKit
import SwiftData
import SwiftUI

/// The Connect page: saved connections on the left, the form on the right.
struct ConnectView: View {
    @Environment(Session.self) private var session

    var body: some View {
        NavigationSplitView {
            SavedConnectionList()
                .navigationSplitViewColumnWidth(min: Layout.sidebarMin, ideal: Layout.sidebarIdeal, max: Layout.sidebarMax)
        } detail: {
            ConnectForm()
        }
        // S-068: a SQLite file dropped on the window opens it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.isFileURL && SQLiteFile.opens($0) }) else { return false }
            session.openSQLiteFile(url)
            return true
        }
        .sheet(isPresented: Binding(get: { session.sshQuestion != nil }, set: { if !$0 { session.cancelSSHQuestion() } })) {
            if let question = session.sshQuestion {
                SSHQuestionSheet(session: session, question: question)
            }
        }
    }
}
