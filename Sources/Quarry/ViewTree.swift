import AppKit

/// Finds AppKit views inside SwiftUI windows, for the self-test and snapshots.
@MainActor
enum ViewTree {
    /// The first view of `type` under `view` (itself included), depth first, that passes `matches`.
    static func first<T: NSView>(_ type: T.Type, in view: NSView?, where matches: (T) -> Bool = { _ in true }) -> T? {
        guard let view else { return nil }
        if let match = view as? T, matches(match) { return match }
        for sub in view.subviews {
            if let match = first(type, in: sub, where: matches) { return match }
        }
        return nil
    }
}
