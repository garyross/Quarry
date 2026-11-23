import Foundation
import NIOSSL

/// The SSL files for a connection (S-058), with `~` expanded. Any connection
/// type can use SSL: TCP/IP, a socket, or through an SSH tunnel.
///
/// Like the `mysql` client: with a CA certificate the server's certificate must
/// be signed by it (its host name is not checked, as servers are often reached
/// by IP or through a tunnel); without one the connection is encrypted but the
/// server is not checked.
public struct SSLOptions: Sendable, Equatable {
    /// The client's private key (PEM), sent with `certificateFile`.
    public var keyFile: String?
    /// The client's certificate (PEM), for accounts created `REQUIRE X509`.
    public var certificateFile: String?
    /// The certificate authority that signed the server's certificate (PEM).
    public var caFile: String?

    public init(keyFile: String? = nil, certificateFile: String? = nil, caFile: String? = nil) {
        self.keyFile = keyFile
        self.certificateFile = certificateFile
        self.caFile = caFile
    }

    /// Whether the server's certificate is checked against a CA.
    public var checksServer: Bool { caFile != nil }

    /// A problem with the files to show before connecting, or nil.
    public func problem(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        if (keyFile == nil) != (certificateFile == nil) {
            return keyFile == nil ? "Choose the key file for the certificate." : "Choose the certificate for the key file."
        }
        for (label, path) in [("key file", keyFile), ("certificate", certificateFile), ("CA certificate", caFile)] {
            if let path, !exists(path) { return "There is no \(label) at \(path)." }
        }
        return nil
    }

    /// The driver's TLS settings. Throws `DatabaseError` when a file can't be read.
    public func tlsConfiguration() throws -> TLSConfiguration {
        var tls = TLSConfiguration.makeClientConfiguration()
        if let caFile {
            tls.trustRoots = .certificates(try load("CA certificate", caFile) { try NIOSSLCertificate.fromPEMFile($0) })
            tls.certificateVerification = .noHostnameVerification
        } else {
            tls.certificateVerification = .none
        }
        if let keyFile, let certificateFile {
            let chain = try load("certificate", certificateFile) { try NIOSSLCertificate.fromPEMFile($0) }
            tls.certificateChain = chain.map { .certificate($0) }
            tls.privateKey = .privateKey(try load("key file", keyFile) { [try NIOSSLPrivateKey(file: $0, format: .pem)] }[0])
        }
        return tls
    }

    private func load<T>(_ label: String, _ path: String, _ read: (String) throws -> [T]) throws -> [T] {
        let items: [T]
        do { items = try read(path) } catch {
            throw DatabaseError(message: "Could not read the \(label) at \(path).",
                                suggestion: "Choose a PEM file. A key must not have a passphrase.")
        }
        guard !items.isEmpty else {
            throw DatabaseError(message: "There is no \(label) in \(path).", suggestion: "Choose a PEM file.")
        }
        return items
    }
}

/// How a connection is encrypted, from the server's own session status (S-058).
public struct Encryption: Sendable, Equatable {
    /// "TLSv1.3".
    public var version: String
    /// "TLS_AES_256_GCM_SHA384".
    public var cipher: String
    /// Whether the server's certificate was checked against a CA.
    public var serverChecked: Bool

    public init(version: String, cipher: String, serverChecked: Bool) {
        self.version = version
        self.cipher = cipher
        self.serverChecked = serverChecked
    }

    /// "SSL (TLSv1.3, TLS_AES_256_GCM_SHA384). The server's certificate was checked against the CA certificate."
    public var description: String {
        "SSL (\(version), \(cipher)). " + (serverChecked
            ? "The server's certificate was checked against the CA certificate."
            : "The server's certificate was not checked: choose a CA certificate to check it.")
    }
}
