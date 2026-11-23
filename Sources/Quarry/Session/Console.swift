import Foundation
import Observation
import QuarryKit

/// The Console's messages on the main actor (S-039): a copy of
/// `ConsoleLog.shared`, refreshed once per burst of statements.
@MainActor @Observable
final class Console {
    static let shared = Console()

    private(set) var messages: [ConsoleMessage] = []
    @ObservationIgnored private let log: ConsoleLog

    init(log: ConsoleLog = .shared) {
        self.log = log
        log.onChange { [weak self] in
            Task { @MainActor in
                self?.reload()
                // Lines arrive without an event, so tell the menu bar (Clear Console, S-040).
                MenuState.shared.refreshResponder()
            }
        }
        reload()
    }

    func reload() {
        log.didRead()
        messages = log.messages
    }

    func clear() {
        log.clear()
    }

    /// The gear menu's settings, kept between launches.
    enum Key {
        static let showsTime = "consoleShowsTime"
        static let showsConnection = "consoleShowsConnection"
        static let showsDatabase = "consoleShowsDatabase"
        static let showsSelectAndShow = "consoleShowsSelectAndShow"
        static let showsHelp = "consoleShowsHelp"
    }

    static let timeFormat = Date.FormatStyle(date: .omitted, time: .standard)
}
