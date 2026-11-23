import Foundation

/// A problem talking to a server, worded for people.
public struct DatabaseError: Error, Sendable, Equatable, LocalizedError {
    /// The server's own words, or a description of the network problem.
    public var message: String
    /// The server's error number (1045 access denied, 1064 syntax), if any.
    public var code: Int?
    /// One line on what to try, when Quarry knows.
    public var suggestion: String?

    public init(message: String, code: Int? = nil, suggestion: String? = nil) {
        self.message = message
        self.code = code
        self.suggestion = suggestion
    }

    public var errorDescription: String? { message }
}
