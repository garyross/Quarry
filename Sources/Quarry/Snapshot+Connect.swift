import AppKit
import QuarryKit
import SwiftUI

/// Snapshot pages for the Connect form, SSH, Connection Lost and connection files.
extension SnapshotPage {
    /// nil: not one of these pages. true: ready now. false: ready once the session's load ends.
    @MainActor
    func prepareConnect(_ session: Session, model: AppModel, local: SavedConnection?) async -> Bool? {
        switch self {
        case .connectionLost, .connectionLostError:
            // S-050: the sheet as a dropped connection shows it; the error page after a failed Reconnect.
            show(.content, "table:customers", in: session)
            await session.currentLoad?.value
            if self == .connectionLostError {
                session.reconnectProblem = DatabaseError(message: "Could not reach 127.0.0.1:3399.",
                                                         suggestion: "Check that the server is running and the host and port are right.")
            }
            session.connectionLost = true
        case .saveConnectionFile:
            // S-055: passwords on, the file password typed twice.
            show(.structure, "table:orders", in: session)
            await session.currentLoad?.value
            session.requestSaveConnectionFile(asSession: false)
            session.connectionFileDraft?.options = .init(connectsOnOpen: true, includesPasswords: true, includesQuery: true,
                                                         includesPlace: true)
            session.connectionFileDraft?.password = "secret"
            session.connectionFileDraft?.confirmation = "secret"
        default:
            return nil
        }
        return false
    }
}
