import Foundation
import QuarryKit
import SwiftData

/// A filter people saved on a table (S-062): its rules and groups, including
/// rules with no value yet, so a saved filter can be opened and finished by
/// typing one value. It belongs to one table, in one database, on one server
/// and user (as favorite databases do).
@Model
final class SavedFilter {
    var uid: UUID = UUID()
    var name: String = ""
    /// `FavoriteDatabase.serverKey(for:)`: the same for every connection to the server and user.
    var serverKey: String = ""
    var database: String = ""
    var table: String = ""
    /// `FilterTree.encoded()`.
    var tree: Data = Data()
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(name: String, place: Place, tree: FilterTree) {
        self.name = name
        serverKey = place.serverKey
        database = place.database
        table = place.table
        self.tree = tree.encoded()
    }

    /// The table a filter belongs to.
    struct Place: Hashable {
        let serverKey: String
        let database: String
        let table: String
    }

    var place: Place { Place(serverKey: serverKey, database: database, table: table) }
    var filter: FilterTree? { FilterTree.decoded(tree) }
}
