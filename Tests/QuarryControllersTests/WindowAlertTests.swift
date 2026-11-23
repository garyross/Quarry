import Foundation
import Testing
import QuarryKit
import QuarryControllers

/// The window's one alert (review 2026-11-20 controllers, card 3).
@Suite struct WindowAlertTests {
    static let orders = DBObject(name: "orders", kind: .table)

    @Test func emptyAndDeleteTableAskWithTheirOwnWords() {
        let empty = WindowAlert.tableEdit(PendingTableEdit(action: .empty, objects: [Self.orders]))
        #expect(empty.isConfirmation)
        #expect(empty.title == "Empty table \u{201C}orders\u{201D}?")
        #expect(empty.confirmTitle == "Empty")
        #expect(empty.tableEdit?.action == .empty && empty.databaseToDelete == nil)
        let delete = WindowAlert.tableEdit(PendingTableEdit(action: .delete, objects: [Self.orders]))
        #expect(delete.confirmTitle == "Delete")
    }

    @Test func ignoreForeignKeysIsTheTableEditsCheckbox() {
        var alert = WindowAlert.tableEdit(PendingTableEdit(action: .delete, objects: [Self.orders]))
        #expect(!alert.ignoreForeignKeys)
        alert.ignoreForeignKeys = true
        #expect(alert.tableEdit?.ignoreForeignKeys == true)
        // Other alerts have no checkbox, and setting it changes nothing.
        var notice = WindowAlert.notice(title: "Done", message: "")
        notice.ignoreForeignKeys = true
        #expect(notice == .notice(title: "Done", message: "") && !notice.ignoreForeignKeys)
    }

    @Test func deleteDatabaseNamesIt() {
        let alert = WindowAlert.deleteDatabase("quarry_old")
        #expect(alert.isConfirmation)
        #expect(alert.title == "Delete database \u{201C}quarry_old\u{201D}?")
        #expect(alert.databaseToDelete == "quarry_old" && alert.tableEdit == nil)
    }

    @Test func aFailureCarriesTheErrorsMessage() {
        let alert = WindowAlert.failure("Couldn’t rename \u{201C}orders\u{201D}",
                                        DatabaseError(message: "Table 'orders2' already exists"))
        #expect(!alert.isConfirmation)
        #expect(alert.title == "Couldn’t rename \u{201C}orders\u{201D}")
        #expect(alert.message == "Table 'orders2' already exists")
        #expect(alert.confirmTitle == "OK")
    }
}
