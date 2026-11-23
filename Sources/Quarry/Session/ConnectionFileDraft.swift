import Foundation
import Observation
import QuarryKit

/// The Save Connection File and Save Session sheets (S-055): what goes in the file.
@Observable
final class ConnectionFileDraft: Identifiable {
    let id = UUID()
    let asSession: Bool
    /// "Local" or "3 tabs in 2 windows", for the sheet's first line.
    let summary: String
    var options: ConnectionDocument.Options
    var password = ""
    var confirmation = ""

    init(asSession: Bool, summary: String) {
        self.asSession = asSession
        self.summary = summary
        options = Self.remembered
    }

    var title: String { asSession ? "Save Session" : "Save Connection File" }

    /// Why Save… is off: passwords need a file password, typed twice.
    var problem: String? {
        guard options.includesPasswords else { return nil }
        if password.isEmpty { return "Enter a file password to encrypt the passwords with." }
        if password != confirmation { return "The two file passwords don’t match." }
        return nil
    }

    var canSave: Bool { problem == nil }

    // The sheet starts with the choices made last time.
    private static let key = "connectionFile.options"

    static var remembered: ConnectionDocument.Options {
        let stored = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        return ConnectionDocument.Options(connectsOnOpen: stored["connect"] as? Bool ?? true,
                                          includesPasswords: stored["passwords"] as? Bool ?? false,
                                          includesQuery: stored["query"] as? Bool ?? false,
                                          includesPlace: stored["place"] as? Bool ?? true)
    }

    func remember() {
        UserDefaults.standard.set(["connect": options.connectsOnOpen, "passwords": options.includesPasswords,
                                   "query": options.includesQuery, "place": options.includesPlace], forKey: Self.key)
    }
}

/// Open… on an encrypted file: the file waits here for its password.
@Observable
final class FileUnlock: Identifiable {
    let id = UUID()
    let url: URL
    let data: Data
    var password = ""
    var error: String?

    init(url: URL, data: Data) {
        self.url = url
        self.data = data
    }
}
