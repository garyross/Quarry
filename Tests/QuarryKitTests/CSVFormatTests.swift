import Testing
@testable import QuarryKit

@Suite("CSV format")
struct CSVFormatTests {
    @Test("Every choice gives the options the export and import sheets gave before")
    func everyCombination() {
        for separator in CSVFormat.Separator.allCases {
            for enclosure in CSVFormat.Enclosure.allCases {
                for escape in CSVFormat.Escape.allCases {
                    for lineEnd in CSVFormat.LineEnd.allCases {
                        for header in [true, false] {
                            let format = CSVFormat(separator: separator, enclosure: enclosure, escape: escape,
                                                   lineEnd: lineEnd, header: header, nullText: "\\N")
                            let expected = DataExport.CSVOptions(
                                fieldSeparator: separator.rawValue, enclosure: enclosure.rawValue,
                                escape: escape == .double ? enclosure.rawValue : "\\",
                                lineEnd: lineEnd.rawValue, header: header, nullText: "\\N")
                            #expect(format.options == expected)
                        }
                    }
                }
            }
        }
    }

    @Test("The defaults are comma, double quotes doubled, LF, field names, NULL")
    func defaults() {
        #expect(CSVFormat().options == DataExport.CSVOptions())
    }

    @Test("Tab, CR and LF are the characters themselves, never escapes")
    func controlCharacters() {
        #expect(CSVFormat.Separator.tab.rawValue == "\t")
        #expect(CSVFormat.LineEnd.crlf.rawValue == "\r\n")
        #expect(!CSVFormat.Separator.allCases.contains { $0.rawValue.contains("\\") })
    }
}
