import Foundation

/// Saved queries (S-034): naming rules and the files they import from and
/// export to. Pure; the app stores the queries.
public enum SavedQueryFile {
    /// One saved query in a file.
    public struct Item: Equatable, Sendable {
        public var name: String
        public var query: String

        public init(name: String, query: String) {
            self.name = name
            self.query = query
        }
    }

    public enum ImportError: Error, Equatable, LocalizedError {
        /// The file reads, but holds no saved queries.
        case noQueries
        /// Not a property list Sequel Pro or Quarry wrote.
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .noQueries: "No saved queries found in this file."
            case .unreadable(let detail): "The file couldn’t be read. \(detail)"
            }
        }
    }

    /// Sequel Pro's export: an .spf property list with these keys.
    public static let fileExtension = "spf"
    static let formatKey = "format"
    static let format = "query favorites"
    static let versionKey = "version"
    static let listKey = "queryFavorites"

    /// Export Selected…: an XML property list Sequel Pro can import too.
    public static func encode(_ items: [Item]) throws -> Data {
        let list: [[String: String]] = items.map { ["name": $0.name, "query": $0.query] }
        let plist: [String: Any] = [versionKey: 1, formatKey: format, "encrypted": false, listKey: list]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Import…: the saved queries in an .spf file (Sequel Pro's or Quarry's).
    /// Entries with no query are skipped; one with no name is named from its query.
    public static func decode(_ data: Data) throws -> [Item] {
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }
        guard let root = plist as? [String: Any] else { throw ImportError.unreadable("It isn’t a saved queries file.") }
        let list = root[listKey] as? [[String: Any]] ?? []
        let items = list.compactMap { entry -> Item? in
            guard let query = entry["query"] as? String,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Item(name: name.isEmpty ? defaultName(for: query) : name, query: query)
        }
        guard !items.isEmpty else { throw ImportError.noQueries }
        return items
    }

    /// Import… of an .sql file: the whole file is one saved query, named after the file.
    public static func sqlItem(fileName: String, text: String) throws -> Item {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.noQueries }
        let base = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        return Item(name: base.isEmpty ? defaultName(for: text) : base, query: text)
    }

    /// The Save Query sheet's first name: the query's first words, at most
    /// `limit` characters, cut at a word.
    public static func defaultName(for query: String, limit: Int = 40) -> String {
        let words = QueryHistory.summary(query)
        guard !words.isEmpty else { return "New Query" }
        guard words.count > limit else { return words }
        let cut = words.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `name`, or "name 2", "name 3"… when the name is in `used` (ignoring case).
    public static func uniqueName(_ name: String, among used: some Sequence<String>) -> String {
        let taken = Set(used.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    /// Duplicate: "name copy", then "name copy 2"…
    public static func copyName(_ name: String, among used: some Sequence<String>) -> String {
        uniqueName("\(name) copy", among: used)
    }

    /// The names an import adds: each made unique among `existing` and the ones before it.
    /// An item whose name and query both match an existing one is dropped.
    public static func merging(_ items: [Item], into existing: [Item]) -> [Item] {
        var used = existing.map(\.name)
        var added: [Item] = []
        for item in items {
            if existing.contains(item) || added.contains(item) { continue }
            let name = uniqueName(item.name, among: used)
            used.append(name)
            added.append(Item(name: name, query: item.query))
        }
        return added
    }
}
