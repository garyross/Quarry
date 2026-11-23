import Foundation
import QuarryKit

/// The one alert a connection window shows over its content (review 2026-11-20
/// controllers, card 3). One value, so a new alert can't be left out of
/// `Session.closeSheets()` and two can't be asked for at once: the newest wins.
package enum WindowAlert: Equatable {
    /// Empty Table… or Delete Table…, asked first, with Ignore foreign keys (S-022).
    case tableEdit(PendingTableEdit)
    /// Delete Database…, asked first (S-019).
    case deleteDatabase(String)
    /// Something finished or failed: a title, a message and OK.
    case notice(title: String, message: String)

    /// Asks before something that can't be undone.
    package var isConfirmation: Bool {
        if case .notice = self { return false }
        return true
    }

    package var title: String {
        switch self {
        case .tableEdit(let edit): edit.title
        case .deleteDatabase(let name): "Delete database \u{201C}\(name)\u{201D}?"
        case .notice(let title, _): title
        }
    }

    package var message: String {
        switch self {
        case .tableEdit(let edit): edit.message
        case .deleteDatabase: "Its tables, views and routines are deleted. This can't be undone."
        case .notice(_, let message): message
        }
    }

    /// The button that goes ahead: "Empty", "Delete", or OK for a notice.
    package var confirmTitle: String {
        switch self {
        case .tableEdit(let edit): edit.buttonTitle
        case .deleteDatabase: "Delete"
        case .notice: "OK"
        }
    }

    /// The Empty or Delete waiting on its answer.
    package var tableEdit: PendingTableEdit? {
        if case .tableEdit(let edit) = self { return edit }
        return nil
    }

    /// The database Delete Database… names.
    package var databaseToDelete: String? {
        if case .deleteDatabase(let name) = self { return name }
        return nil
    }

    /// The alert's Ignore foreign keys checkbox; only Empty and Delete Table have one.
    package var ignoreForeignKeys: Bool {
        get { tableEdit?.ignoreForeignKeys ?? false }
        set {
            guard case .tableEdit(var edit) = self else { return }
            edit.ignoreForeignKeys = newValue
            self = .tableEdit(edit)
        }
    }

    /// A notice for a failed action, with the error's message.
    package static func failure(_ title: String, _ error: Error) -> WindowAlert {
        .notice(title: title, message: DatabaseError.from(error).message)
    }
}
