import Foundation

/// A database name that matches what people typed in Go to Database (S-020),
/// with the parts that matched, for bold text in the list.
public struct DatabaseMatch: Equatable, Sendable {
    public let name: String
    /// Matched parts of `name`, in order; consecutive letters are one range.
    public let ranges: [Range<String.Index>]
}

/// Go to Database's search, as Sequel Pro's: the typed letters appear in the
/// name in order but not necessarily together ("qdm" finds quarry_demo).
/// A search in quotes ("demo" or 'demo') finds the text as typed. Case,
/// accents and full-width letters are ignored. Names with fewer separate
/// matched parts sort first, then by name.
public enum DatabaseMatcher {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Every name when the search is empty, in the order given.
    public static func matches(_ search: String, in names: [String]) -> [DatabaseMatch] {
        guard !search.isEmpty else { return names.map { DatabaseMatch(name: $0, ranges: []) } }
        let word = isWordSearch(search)
        let needle = word ? String(search.dropFirst().dropLast()) : search
        guard !needle.isEmpty else { return names.map { DatabaseMatch(name: $0, ranges: []) } }
        let found = names.compactMap { name -> DatabaseMatch? in
            if word {
                return name.range(of: needle, options: options).map { DatabaseMatch(name: name, ranges: [$0]) }
            }
            return scattered(needle, in: name).map { DatabaseMatch(name: name, ranges: $0) }
        }
        return found.sorted { a, b in
            if !word, a.ranges.count != b.ranges.count { return a.ranges.count < b.ranges.count }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// `"demo"` or `'demo'`: find the text as typed.
    public static func isWordSearch(_ search: String) -> Bool {
        guard search.count > 1, let first = search.first, first == "\"" || first == "'" else { return false }
        return search.last == first
    }

    /// Each letter of `needle` in `name`, in order, after the last one found;
    /// nil when one is missing. Neighbouring matches merge into one range.
    static func scattered(_ needle: String, in name: String) -> [Range<String.Index>]? {
        if name.compare(needle, options: options) == .orderedSame { return [name.startIndex..<name.endIndex] }
        var ranges: [Range<String.Index>] = []
        var start = name.startIndex
        for letter in needle {
            guard let found = name.range(of: String(letter), options: options, range: start..<name.endIndex) else {
                return nil
            }
            if let last = ranges.last, last.upperBound == found.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<found.upperBound
            } else {
                ranges.append(found)
            }
            start = found.upperBound
        }
        return ranges
    }
}
