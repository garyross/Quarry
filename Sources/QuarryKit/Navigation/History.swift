import Foundation

/// Back and Forward, like a browser: going somewhere new from the middle of
/// the history drops the places ahead (S-017 records followed foreign keys;
/// S-038 adds every table and view).
public struct History<Place: Equatable>: Equatable {
    public private(set) var back: [Place] = []
    public private(set) var forward: [Place] = []
    /// The most places kept behind; the oldest go first.
    public var limit: Int

    public init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Leaving `current` for somewhere new: it goes behind, and the places ahead go.
    public mutating func visit(leaving current: Place) {
        if back.last != current { back.append(current) }
        if back.count > limit { back.removeFirst(back.count - limit) }
        forward.removeAll()
    }

    /// Back: the place to show; `current` goes ahead. Nil when there is nowhere to go.
    public mutating func goBack(from current: Place) -> Place? {
        guard let place = back.popLast() else { return nil }
        forward.append(current)
        return place
    }

    /// Forward: the place to show; `current` goes behind.
    public mutating func goForward(from current: Place) -> Place? {
        guard let place = forward.popLast() else { return nil }
        back.append(current)
        return place
    }

    public mutating func removeAll() {
        back.removeAll()
        forward.removeAll()
    }
}

extension History: Sendable where Place: Sendable {}
