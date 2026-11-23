import Foundation
import QuarryKit

/// Database > View Using Encoding (S-056).
extension Session {
    /// SET NAMES on this window's connection, then the current view reads again.
    @discardableResult
    func setViewEncoding(_ encoding: ViewEncoding) -> Task<Void, Never>? {
        guard phase == .connected, !isSQLite, let client, encoding != viewEncoding else { return nil }
        return Task {
            do {
                try await client.setViewEncoding(encoding)
                viewEncoding = encoding
                reloadCurrentView(force: true)
                await currentLoad?.value
            } catch {
                alert = .failure("Couldn’t Change the Encoding", error)
            }
        }
    }
}
