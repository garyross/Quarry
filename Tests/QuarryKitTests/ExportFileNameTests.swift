import Foundation
import Testing
@testable import QuarryKit

@Suite("Export file names (S-043)")
struct ExportFileNameTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    /// 2026-11-19 14:05:09 UTC.
    let date = Date(timeIntervalSince1970: 1_795_097_109)
    var values: ExportFileName.Values {
        ExportFileName.Values(database: "quarry_demo", table: "orders", host: "127.0.0.1", connection: "Local", date: date)
    }

    @Test func expandsEveryToken() {
        let name = ExportFileName("{database}-{table}-{host}-{connection}-{date}-{year}{month}{day}-{24-hour-time}")
        #expect(name.expand(values, calendar: calendar) == "quarry_demo-orders-127.0.0.1-Local-2026-11-19-20261119-14-05-09")
        let time = ExportFileName("{time}").expand(values, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
        #expect(time == "2-05 PM")
    }

    @Test func keepsTextAndUnknownBraces() {
        #expect(ExportFileName("backup {nope} {database}").expand(values, calendar: calendar) == "backup {nope} quarry_demo")
    }

    @Test func colonsAndSlashesBecomeHyphens() {
        let odd = ExportFileName.Values(database: "a/b", table: "c:d", date: date)
        #expect(ExportFileName("{database} {table}").expand(odd, calendar: calendar) == "a-b c-d")
    }

    @Test func emptyPatternOrResultFallsBack() {
        #expect(ExportFileName("  ").isEmpty)
        #expect(ExportFileName("{table}").expand(ExportFileName.Values(database: "x"), calendar: calendar) == "")
    }

    @Test func perTableNamesAreUnique() {
        #expect(ExportFileName("").perTable(values, calendar: calendar) == "orders")
        #expect(ExportFileName("{table}_{date}").perTable(values, calendar: calendar) == "orders_2026-11-19")
        #expect(ExportFileName("{database}").perTable(values, calendar: calendar) == "quarry_demo_orders")
        #expect(ExportFileName("{database}").contains(.database) && !ExportFileName("{database}").contains(.table))
    }
}
