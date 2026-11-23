import Foundation
import Testing
@testable import QuarryKit

@Suite("Table Options")
struct TableOptionsTests {
    @Test func statements() {
        func sql(_ option: TableOption) -> String { option.sql(table: "my `t`", database: "db") }
        #expect(sql(.engine("Aria")) == "ALTER TABLE `db`.`my ``t``` ENGINE = `Aria`")
        #expect(sql(.charset("latin1")) == "ALTER TABLE `db`.`my ``t``` CHARACTER SET = `latin1`")
        #expect(sql(.collation("utf8mb4_bin")) == "ALTER TABLE `db`.`my ``t``` COLLATE = `utf8mb4_bin`")
        #expect(sql(.comment("It's")) == "ALTER TABLE `db`.`my ``t``` COMMENT = 'It''s'"
            || sql(.comment("It's")) == "ALTER TABLE `db`.`my ``t``` COMMENT = 'It\\'s'")
        #expect(sql(.autoIncrement(42)) == "ALTER TABLE `db`.`my ``t``` AUTO_INCREMENT = 42")
    }

    @Test func typedAutoIncrement() {
        #expect(TableOption.autoIncrement(from: "1,204") == 1204)
        #expect(TableOption.autoIncrement(from: " 7 ") == 7)
        #expect(TableOption.autoIncrement(from: "0") == nil)
        #expect(TableOption.autoIncrement(from: "-3") == nil)
        #expect(TableOption.autoIncrement(from: "abc") == nil)
        #expect(TableOption.autoIncrement(from: "") == nil)
    }

    @Test func readsStatus() {
        let names = ["Name", "Engine", "Row_format", "Rows", "Data_length", "Auto_increment", "Collation", "Comment"]
        let result = StatementResult(sql: "", columns: names.map { ResultColumn(name: $0) }, rows: [
            [.text("orders"), .text("InnoDB"), .text("Dynamic"), .text("12"), .text("16384"), .null,
             .text("utf8mb4_uca1400_ai_ci"), .text("")],
        ], affectedRows: nil, duration: .zero)
        let status = TableStatus(result)
        #expect(status?.engine == "InnoDB" && status?.rows == 12 && status?.dataLength == 16384)
        #expect(status?.autoIncrement == nil && status?.maxDataLength == nil)
        #expect(status?.charset(in: nil) == "utf8mb4")
        #expect(TableStatus(StatementResult(sql: "", columns: [], rows: [], affectedRows: nil, duration: .zero)) == nil)
    }

    @Test func charsetFromCatalog() {
        let catalog = CharsetCatalog(charsets: [], collations: [("ucs2_general_ci", "ucs2"), ("latin1_bin", "latin1")],
                                     serverCharset: "utf8mb4", serverCollation: "utf8mb4_general_ci")
        #expect(TableStatus(collation: "latin1_bin").charset(in: catalog) == "latin1")
        #expect(TableStatus(collation: "binary").charset(in: catalog) == "binary")
    }
}
