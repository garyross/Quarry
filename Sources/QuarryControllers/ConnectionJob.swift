import Foundation
import QuarryKit

/// A long job (an export or an import) on a connection of its own, so the
/// window keeps browsing: it owns the task, the connection and the outcome.
/// The job's work opens the connection with `connection()` when it needs
/// one, reports progress with `reporter()`, and throws to fail; a cancel is
/// told apart from a failure, and the connection is closed at the end.
@MainActor @Observable
package final class ConnectionJob<Progress: Sendable> {
    /// The progress so far; a late report after the end is dropped.
    package var progress: Progress?
    /// "Couldn’t export: …", after a failure.
    package private(set) var error: String?
    package private(set) var wasCancelled = false
    private var task: Task<Void, Never>?
    @ObservationIgnored private var connection: DatabaseClient?
    @ObservationIgnored private let client: DatabaseClient
    @ObservationIgnored private let failurePrefix: String
    @ObservationIgnored private let clearsProgress: Bool
    @ObservationIgnored private let readOnly: Bool

    /// `failurePrefix` starts the error text ("Couldn’t import: ").
    /// `clearsProgress` drops the progress when the job ends.
    /// `readOnly` opens a SQLite file read only for the job (an export, S-071).
    package init(client: DatabaseClient, failurePrefix: String, clearsProgress: Bool, readOnly: Bool = false) {
        self.client = client
        self.failurePrefix = failurePrefix
        self.clearsProgress = clearsProgress
        self.readOnly = readOnly
    }

    package var isRunning: Bool { task != nil }

    /// Clears the last run's outcome.
    package func reset() {
        error = nil
        wasCancelled = false
    }

    /// Runs `work`. The returned task ends when it is done, failed or was cancelled.
    @discardableResult
    package func start(progress initial: Progress,
               _ work: @escaping @MainActor (ConnectionJob<Progress>) async throws -> Void) -> Task<Void, Never> {
        reset()
        progress = initial
        let job = Task {
            do {
                try await work(self)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    wasCancelled = true
                } else {
                    self.error = failurePrefix + DatabaseError.from(error).message
                }
            }
            await connection?.close()
            connection = nil
            if clearsProgress { progress = nil }
            task = nil
        }
        task = job
        return job
    }

    /// The job's own connection, opened on first use and closed when the job ends.
    package func connection() async throws -> DatabaseClient {
        if let connection { return connection }
        let opened = try await client.secondConnection(readOnly: readOnly)
        connection = opened
        return opened
    }

    /// Progress updates from any thread, shown while the job runs.
    package func reporter() -> @Sendable (Progress) -> Void {
        { progress in
            Task { @MainActor in
                // A late update after the end leaves the finished sheet alone.
                guard self.task != nil else { return }
                self.progress = progress
            }
        }
    }

    /// Stops the job between steps and kills the statement running now
    /// (KILL QUERY), so a slow SELECT or INSERT doesn't hold the cancel up.
    package func cancel() {
        task?.cancel()
        if let connection { Task { try? await connection.cancelRunningQuery() } }
    }
}
