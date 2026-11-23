import Foundation
import Testing
@testable import QuarryKit

@Suite("Field definitions for ALTER TABLE")
struct FieldDefinitionTests {
    private func info(_ name: String, _ type: String, null: Bool = false, default value: String? = nil,
                      extra: String = "", collation: String? = nil, comment: String = "") -> FieldInfo {
        FieldInfo(name: name, fullType: type, isNullable: null, key: "", defaultValue: value, extra: extra,
                  collation: collation, comment: comment)
    }

    @Test func integers() {
        let id = FieldDefinition(info("id", "int(10) unsigned", extra: "auto_increment"))
        #expect(id.sql == "`id` INT(10) UNSIGNED NOT NULL AUTO_INCREMENT")
        let count = FieldDefinition(info("n", "bigint(20) unsigned zerofill", null: true, default: "0"))
        #expect(count.sql == "`n` BIGINT(20) UNSIGNED ZEROFILL NULL DEFAULT '0'")
    }

    @Test func decimalsAndBits() {
        #expect(FieldDefinition(info("price", "decimal(10,2)")).sql == "`price` DECIMAL(10,2) NOT NULL")
        #expect(FieldDefinition(info("flags", "bit(8)", default: "b'0'")).sql == "`flags` BIT(8) NOT NULL DEFAULT b'0'")
    }

    @Test func stringsKeepTheirCollation() {
        let name = FieldDefinition(info("name", "varchar(120)", collation: "utf8mb4_unicode_ci", comment: "It's a name"))
        #expect(name.sql == "`name` VARCHAR(120) COLLATE utf8mb4_unicode_ci NOT NULL COMMENT 'It\\'s a name'"
                || name.sql == "`name` VARCHAR(120) COLLATE utf8mb4_unicode_ci NOT NULL COMMENT 'It''s a name'")
        let country = FieldDefinition(info("country", "char(2)", default: "US", collation: "utf8mb4_unicode_ci"))
        #expect(country.sql == "`country` CHAR(2) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'US'")
        var withCharset = country
        withCharset.charset = "latin1"
        withCharset.collation = nil
        #expect(withCharset.sql.contains("CHARACTER SET latin1 NOT NULL"))
    }

    @Test func textBlobJSONAndSpatialTakeNoLength() {
        #expect(FieldDefinition(info("notes", "text", null: true, collation: "utf8mb4_unicode_ci")).sql
                == "`notes` TEXT COLLATE utf8mb4_unicode_ci NULL DEFAULT NULL")
        #expect(FieldDefinition(info("img", "blob", null: true)).sql == "`img` BLOB NULL DEFAULT NULL")
        #expect(FieldDefinition(info("doc", "json", null: true)).sql == "`doc` JSON NULL DEFAULT NULL")
        #expect(FieldDefinition(info("at", "point")).sql == "`at` POINT NOT NULL")
    }

    @Test func enumsKeepTheirValues() {
        let status = FieldDefinition(info("status", "enum('draft','active')", default: "draft", collation: "utf8mb4_bin"))
        #expect(status.sql == "`status` ENUM('draft','active') COLLATE utf8mb4_bin NOT NULL DEFAULT 'draft'")
    }

    @Test func datesAndTimestamps() {
        let created = FieldDefinition(info("created_at", "datetime", default: "current_timestamp()"))
        #expect(created.defaultValue == .expression("current_timestamp()"))
        #expect(created.sql == "`created_at` DATETIME NOT NULL DEFAULT current_timestamp()")
        let updated = FieldDefinition(info("updated_at", "timestamp(3)", default: "current_timestamp(3)",
                                           extra: "on update current_timestamp(3)"))
        #expect(updated.extra == .onUpdate)
        #expect(updated.sql == "`updated_at` TIMESTAMP(3) NOT NULL DEFAULT current_timestamp(3) ON UPDATE CURRENT_TIMESTAMP(3)")
        // MySQL 8 prints the expression without parentheses and flags it.
        let mysql = FieldDefinition(info("t", "timestamp", default: "CURRENT_TIMESTAMP",
                                         extra: "DEFAULT_GENERATED on update CURRENT_TIMESTAMP"))
        #expect(mysql.sql == "`t` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP")
        #expect(FieldDefinition(info("d", "date", default: "2026-01-01")).sql == "`d` DATE NOT NULL DEFAULT '2026-01-01'")
        #expect(FieldDefinition(info("y", "year(4)")).sql == "`y` YEAR(4) NOT NULL")
    }

    @Test func generatedAndInvisibleFields() {
        #expect(FieldDefinition(info("total", "int(11)", null: true, extra: "VIRTUAL GENERATED")).isGenerated)
        #expect(!FieldDefinition(info("t", "timestamp", extra: "DEFAULT_GENERATED")).isGenerated)
        #expect(FieldDefinition(info("h", "int(11)", null: true, extra: "INVISIBLE")).sql == "`h` INT(11) NULL DEFAULT NULL INVISIBLE")
    }

    @Test func typedDefaults() {
        #expect(FieldDefault(typed: "") == .none)
        #expect(FieldDefault(typed: "CURRENT_TIMESTAMP") == .expression("CURRENT_TIMESTAMP"))
        #expect(FieldDefault(typed: "now()") == .expression("now()"))
        #expect(FieldDefault(typed: "b'101'") == .expression("b'101'"))
        #expect(FieldDefault(typed: "now") == .value("now"))
        #expect(FieldDefault(typed: "12") == .value("12"))
        // DEFAULT NULL only on a field that allows NULL.
        var field = FieldDefinition(name: "x", type: "int", isNullable: false, defaultValue: .null)
        #expect(field.sql == "`x` INT NOT NULL")
        field.isNullable = true
        #expect(field.sql == "`x` INT NULL DEFAULT NULL")
    }

    @Test func aTypeChangeClearsOptionsThatNoLongerApply() {
        let id = FieldDefinition(info("id", "int(10) unsigned zerofill", extra: "auto_increment"))
        let text = id.changingType(to: "varchar")
        #expect(!text.isUnsigned && !text.isZerofill)
        #expect(text.extra == .none)
        #expect(text.length == "255")
        #expect(text.sql == "`id` VARCHAR(255) NOT NULL")

        let wider = id.changingType(to: "bigint")
        #expect(wider.length == "10" && wider.isUnsigned && wider.extra == .autoIncrement)

        let name = FieldDefinition(info("name", "varchar(120)", null: true, default: "x", collation: "utf8mb4_bin"))
        let number = name.changingType(to: "int")
        #expect(number.collation == nil && number.length == "" && number.defaultValue == .null)
        let longer = name.changingType(to: "text")
        #expect(longer.collation == "utf8mb4_bin" && longer.length == "" && longer.defaultValue == .null)
        #expect(name.changingType(to: "char").length == "120")

        let created = FieldDefinition(info("c", "datetime(3)", default: "current_timestamp(3)", extra: "on update current_timestamp(3)"))
        let stamp = created.changingType(to: "timestamp")
        #expect(stamp.extra == .onUpdate && stamp.defaultValue == .expression("current_timestamp(3)") && stamp.length == "3")
        let day = created.changingType(to: "date")
        #expect(day.extra == .none && day.defaultValue == .none && day.length == "")
    }

    @Test func familiesAndLengths() {
        #expect(TypeFamily(type: "INTEGER") == .integer)
        #expect(TypeFamily(type: "uuid") == .other)
        #expect(FieldDefinition.takesLength("varchar") && !FieldDefinition.takesLength("longtext"))
        #expect(!FieldDefinition.takesLength("date") && FieldDefinition.takesLength("datetime"))
        #expect(FieldExtra.autoIncrement.applies(to: "bigint") && !FieldExtra.autoIncrement.applies(to: "varchar"))
    }

    @Test func statements() {
        let field = FieldDefinition(name: "email", type: "varchar", length: "190", isNullable: true, defaultValue: .null)
        #expect(FieldChange.addSQL(field, to: "customers", in: "shop", position: .after("name"))
                == "ALTER TABLE `shop`.`customers` ADD `email` VARCHAR(190) NULL DEFAULT NULL AFTER `name`")
        #expect(FieldChange.changeSQL("mail", to: field, in: "customers", database: "shop")
                == "ALTER TABLE `shop`.`customers` CHANGE `mail` `email` VARCHAR(190) NULL DEFAULT NULL")
        #expect(FieldChange.changeSQL("email", to: field, in: "customers", database: "shop", position: .first)
                .hasSuffix("DEFAULT NULL FIRST"))
        #expect(FieldChange.dropSQL(["a", "b"], from: "t", in: "shop") == "ALTER TABLE `shop`.`t` DROP `a`, DROP `b`")
    }

    @Test func dragPositions() {
        let names = ["id", "name", "email", "country"]
        #expect(FieldChange.dropPosition(moving: 2, to: 0, in: names) == .first)
        #expect(FieldChange.dropPosition(moving: 0, to: 3, in: names) == .after("email"))
        #expect(FieldChange.dropPosition(moving: 0, to: 4, in: names) == .after("country"))
        #expect(FieldChange.dropPosition(moving: 1, to: 1, in: names) == nil)
        #expect(FieldChange.dropPosition(moving: 1, to: 2, in: names) == nil)
    }

    @Test func duplicates() {
        let id = FieldDefinition(info("id", "int(10) unsigned", extra: "auto_increment"))
        let copy = FieldChange.duplicate(id, existing: ["id", "id_copy"])
        #expect(copy.name == "id_copy2" && copy.extra == .none && copy.isUnsigned)
    }
}
