import SwiftUI
import QuarryControllers

/// Every animation in Quarry. The feeling is "quick and confident": almost
/// nothing moves. View switches, search results and the grid never animate.
enum Motion {
    /// Hover fills and small presses.
    static let hover: Animation = .linear(duration: 0.08)
    /// Dimming old content when a load takes long.
    static let dim: Animation = .easeOut(duration: 0.15)
    /// Wait this long before showing a spinner or dimming: shorter loads show nothing.
    static let loadingDelay: Duration = LoadState.spinnerDelay

    /// Use instead of `withAnimation`, so Reduce Motion turns it off everywhere.
    static func run(_ animation: Animation, reduceMotion: Bool, _ body: () -> Void) {
        if reduceMotion { body() } else { withAnimation(animation, body) }
    }
}
