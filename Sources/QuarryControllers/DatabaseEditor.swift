import Foundation
import Observation
import QuarryKit

/// The Duplicate Database, Rename Database and Change Character Set sheets
/// (S-019): one controller, since they share the source, a name check, the
/// character set menus and a progress line.
@Observable
package final class DatabaseEditor: Identifiable {
    package enum Mode { case duplicate, rename, alter }

    package let id = UUID()
    package let mode: Mode
    package let source: String
    private let existing: [String]

    package var name: String
    package var withRows = true
    /// Change Character Set only. Choosing another character set clears the collation.
    package var charset: String? {
        didSet { if charset != oldValue { collation = nil } }
    }
    package var collation: String?

    package private(set) var catalog: CharsetCatalog?
    package private(set) var error: DatabaseError?
    package private(set) var progress: TransferProgress?
    package private(set) var isWorking = false
    /// Set when the job went through but some objects failed: the sheet lists them.
    package private(set) var problems: [String] = []

    package init(mode: Mode, source: String, existing: [String]) {
        self.mode = mode
        self.source = source
        self.existing = existing
        name = mode == .duplicate ? source + "_copy" : source
    }

    package var title: String {
        switch mode {
        case .duplicate: "Duplicate Database"
        case .rename: "Rename Database"
        case .alter: "Change Character Set"
        }
    }

    package var actionTitle: String {
        switch mode {
        case .duplicate: "Duplicate"
        case .rename: "Rename"
        case .alter: "Change"
        }
    }

    package var isFinished: Bool { !problems.isEmpty }

    /// Why the new name cannot be used; nil when it can, or is empty.
    package var nameProblem: String? {
        guard mode != .alter else { return nil }
        if mode == .rename, name == source { return nil }
        return NewDatabase.problem(with: name, existing: existing)
    }

    package var canRun: Bool {
        guard !isWorking, !isFinished else { return false }
        switch mode {
        case .alter: return catalog != nil && charset != nil
        case .duplicate: return !name.isEmpty && nameProblem == nil
        case .rename: return !name.isEmpty && name != source && nameProblem == nil
        }
    }

    // MARK: Change Character Set

    /// Loads the server's character sets and the database's own, which the menus start on.
    package func load(_ client: DatabaseClient) async {
        do {
            let catalog = try await client.charsetCatalog()
            let options = try await client.options(of: source)
            self.catalog = catalog
            charset = options.charset
            // The character set's default shows as "Default (…)", not as a choice.
            collation = options.collation == catalog.defaultCollation(for: options.charset) ? nil : options.collation
        } catch {
            self.error = DatabaseError.from(error)
        }
    }

    package var collations: [String] { catalog?.collations(for: charset) ?? [] }

    package var defaultCollationTitle: String {
        guard let catalog, let charset else { return "Default" }
        let name = catalog.defaultCollation(for: charset)
        return name.isEmpty ? "Default" : "Default (\(name))"
    }

    // MARK: Running

    /// "Copying orders (3 of 9)…".
    package var progressText: String? {
        guard isWorking else { return nil }
        guard let progress, progress.total > 0 else { return mode == .alter ? "Changing…" : "Reading the database…" }
        return "\(progress.text) (\(min(progress.done + 1, progress.total)) of \(progress.total))…"
    }

    /// Runs the job. True when it went through, even with problems (the
    /// new or renamed database exists then); `problems` keeps the sheet open.
    package func run(_ client: DatabaseClient) async -> Bool {
        guard canRun else { return false }
        isWorking = true
        defer { isWorking = false }
        error = nil
        progress = nil
        let report: @Sendable (TransferProgress) -> Void = { [weak self] step in
            Task { @MainActor in self?.progress = step }
        }
        do {
            switch mode {
            case .duplicate:
                problems = try await client.duplicate(source, to: name, withRows: withRows, progress: report).problems
            case .rename:
                problems = try await client.rename(source, to: name, progress: report).problems
            case .alter:
                guard let charset else { return false }
                try await client.alter(AlterDatabase(name: source, charset: charset, collation: collation))
            }
            return true
        } catch {
            self.error = DatabaseError.from(error)
            return false
        }
    }
}
