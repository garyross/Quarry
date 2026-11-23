import Foundation

/// The Query view's history (S-033): the queries run on one server and user,
/// newest first, each once, at most `limit` of them. Pure rules; the app
/// stores the entries.
public enum QueryHistory {
    /// Settings > General: Keep the last N queries.
    public static let defaultLimit = 20
    public static let limitRange = 1...100

    public static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, limitRange.lowerBound), limitRange.upperBound)
    }

    /// What one run records: its statements, joined as Sequel Pro does, with
    /// the trailing semicolons and outer blank lines dropped. Nil for nothing.
    public static func entry(for statements: [String]) -> String? {
        let parts = statements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasSuffix(";") ? String($0.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ";\n")
    }

    /// `entries` (newest first) with `query` on top, an earlier copy removed,
    /// and the oldest dropped past `limit`.
    public static func adding(_ query: String, to entries: [String], limit: Int) -> [String] {
        var result = [query] + entries.filter { $0 != query }
        let limit = clampedLimit(limit)
        if result.count > limit { result.removeLast(result.count - limit) }
        return result
    }

    /// The entries that contain every word of `search`, ignoring case; all of them when it is blank.
    public static func matches(_ search: String, in entries: [String]) -> [String] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            words.allSatisfy { entry.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// One line for a menu or list: whitespace runs become one space.
    public static func summary(_ entry: String) -> String {
        entry.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Copy History and Save History…: every entry, oldest first, each ending in a semicolon.
    public static func script(_ entries: [String]) -> String {
        entries.reversed().map { $0 + ";\n" }.joined()
    }
}

/// Previous and Next Query from History (S-033). Starts before the newest
/// entry; Previous goes older, Next newer. Nil at either end (the app beeps).
public struct HistoryStepper: Equatable, Sendable {
    /// Index of the entry last inserted; -1 before the first step.
    public private(set) var offset = -1

    public init() {}

    public mutating func reset() { offset = -1 }

    public mutating func previous(count: Int) -> Int? { step(by: 1, count: count) }
    public mutating func next(count: Int) -> Int? { step(by: -1, count: count) }

    private mutating func step(by delta: Int, count: Int) -> Int? {
        let target = offset + delta
        guard target >= 0, target < count else { return nil }
        offset = target
        return target
    }
}
