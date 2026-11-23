import Foundation
import Testing
@testable import QuarryKit

@Suite("New Table")
struct NewTableTests {
    @Test func defaultsAreLeftOut() {
        #expect(NewTable(name: "notes").sql
            == "CREATE TABLE `notes` (`id` INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY)")
    }

    @Test func choicesAreQuoted() {
        let table = NewTable(name: "my `notes`", engine: "Aria", charset: "latin1", collation: "latin1_bin")
        #expect(table.sql == "CREATE TABLE `my ``notes``` (`id` INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY)"
            + " ENGINE = `Aria` DEFAULT CHARACTER SET `latin1` COLLATE `latin1_bin`")
    }

    @Test func csvHasNoPrimaryKey() {
        #expect(NewTable(name: "t", engine: "CSV").sql == "CREATE TABLE `t` (`id` INT UNSIGNED NOT NULL) ENGINE = `CSV`")
    }

    @Test func names() {
        let existing = ["orders", "order_totals"]
        #expect(NewTable.problem(with: "", existing: existing) == nil)
        #expect(NewTable.problem(with: "notes", existing: existing) == nil)
        #expect(NewTable.problem(with: "Orders", existing: existing) == "A table or view named “Orders” already exists.")
        #expect(NewTable.problem(with: "notes ", existing: existing) == "A table name can’t end with a space.")
        #expect(NewTable.problem(with: "   ", existing: existing) == "A table name can’t be only spaces.")
        #expect(NewTable.problem(with: String(repeating: "a", count: 65), existing: existing)
            == "A table name can be at most 64 characters.")
    }

    @Test func enginesSortByName() {
        let defaults = TableDefaults(engines: ["MyISAM", "InnoDB", "Aria", "CSV"], defaultEngine: "InnoDB",
                                     charset: "utf8mb4", collation: "utf8mb4_general_ci")
        #expect(defaults.engines == ["Aria", "CSV", "InnoDB", "MyISAM"])
    }
}
