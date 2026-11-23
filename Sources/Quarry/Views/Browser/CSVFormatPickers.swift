import QuarryKit
import SwiftUI

/// The CSV choices both sheets show, in Sequel Pro's words: how fields are
/// separated, enclosed and escaped, how lines end, the first row's field
/// names, and NULL's text. `reading` gives the Import sheet's help.
struct CSVFormatPickers: View {
    @Binding var format: CSVFormat
    let reading: Bool

    var body: some View {
        Picker("Fields separated by", selection: $format.separator) {
            ForEach(CSVFormat.Separator.allCases) { Text($0.title).tag($0) }
        }
        Picker("Fields enclosed by", selection: $format.enclosure) {
            ForEach(CSVFormat.Enclosure.allCases) { Text($0.title).tag($0) }
        }
        .help(reading ? "" : "Text goes between these; numbers and NULL never do")
        Picker("Escape quotes by", selection: $format.escape) {
            ForEach(CSVFormat.Escape.allCases) { Text($0.title).tag($0) }
        }
        .help("How a quote inside a value is written: \"\" (Excel, Numbers) or \\\" (MySQL’s LOAD DATA)")
        Picker("Lines end with", selection: $format.lineEnd) {
            ForEach(CSVFormat.LineEnd.allCases) { Text($0.title).tag($0) }
        }
        .help(reading ? "LF also reads files whose lines end with CRLF" : "")
        Toggle("Field names in the first row", isOn: $format.header)
        TextField("NULL as", text: $format.nullText, prompt: Text(reading ? "none" : "empty"))
            .help(reading ? "Unquoted text that means NULL; \\N always does"
                          : "The text written for NULL, without quotes; MySQL’s LOAD DATA reads \\N")
    }
}
