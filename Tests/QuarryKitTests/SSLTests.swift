import Foundation
import Testing
@testable import QuarryKit
import QuarryTestSupport

/// S-058: the SSL files a connection uses, and what they check.
struct SSLOptionsTests {
    @Test func offMeansNoOptions() {
        var details = ConnectionDetails(user: "quarry", sslCA: "/tmp/ca.pem")
        #expect(details.ssl == nil)
        details.useSSL = true
        #expect(details.ssl == SSLOptions(caFile: "/tmp/ca.pem"))
    }

    @Test func blanksAreNilAndTildeExpands() {
        let details = ConnectionDetails(user: "quarry", useSSL: true, sslKey: "~/k.pem", sslCertificate: " ", sslCA: "")
        let ssl = details.ssl
        #expect(ssl?.keyFile == NSHomeDirectory() + "/k.pem")
        #expect(ssl?.certificateFile == nil)
        #expect(ssl?.caFile == nil)
        #expect(ssl?.checksServer == false)
    }

    @Test func keyAndCertificateGoTogether() {
        let all: (String) -> Bool = { _ in true }
        #expect(SSLOptions(keyFile: "/k").problem(exists: all) == "Choose the certificate for the key file.")
        #expect(SSLOptions(certificateFile: "/c").problem(exists: all) == "Choose the key file for the certificate.")
        #expect(SSLOptions(keyFile: "/k", certificateFile: "/c").problem(exists: all) == nil)
        #expect(SSLOptions().problem(exists: all) == nil)
    }

    @Test func missingFilesAreNamed() {
        let none: (String) -> Bool = { _ in false }
        #expect(SSLOptions(caFile: "/nope/ca.pem").problem(exists: none) == "There is no CA certificate at /nope/ca.pem.")
        let details = ConnectionDetails(user: "quarry", useSSL: true, sslCA: "/nope/ca.pem")
        #expect(details.problem == "There is no CA certificate at /nope/ca.pem.")
    }

    @Test func unreadableFileIsADatabaseError() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("quarry-not-a-cert.pem")
        try? "hello".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: DatabaseError.self) { try SSLOptions(caFile: file.path).tlsConfiguration() }
    }

    @Test func encryptionSaysWhetherTheServerWasChecked() {
        #expect(Encryption(version: "TLSv1.3", cipher: "X", serverChecked: true).description.contains("was checked"))
        #expect(Encryption(version: "TLSv1.3", cipher: "X", serverChecked: false).description.contains("was not checked"))
    }
}

/// S-058 against the test server, whose certificates tools/testdb.sh makes in test-db/ssl.
@Suite("SSL on the test server", .enabled(if: TestServer.isRunning))
struct SSLServerTests {
    static let folder = NSHomeDirectory() + "/Library/Developer/Quarry/test-db/ssl/"

    static func details(user: String = "quarry", ca: String = "ca.pem", client: Bool = false) -> ConnectionDetails {
        var details = TestServer.details
        details.user = user
        details.useSSL = true
        details.sslCA = ca.isEmpty ? "" : folder + ca
        if client {
            details.sslKey = folder + "client-key.pem"
            details.sslCertificate = folder + "client-cert.pem"
        }
        return details
    }

    @Test func plainConnectionsStayPlain() async throws {
        let client = try await DatabaseClient.connect(TestServer.details)
        #expect(client.encryption == nil)
        let rows = try await client.run("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
        #expect(rows.string(0, "Value") == "")
        await client.close()
    }

    @Test func checkedAgainstTheCA() async throws {
        let client = try await DatabaseClient.connect(Self.details())
        #expect(client.encryption?.serverChecked == true)
        #expect(client.encryption?.cipher.isEmpty == false)
        await client.close()
    }

    @Test func withoutACAItEncryptsWithoutChecking() async throws {
        let client = try await DatabaseClient.connect(Self.details(ca: ""))
        #expect(client.encryption?.serverChecked == false)
        await client.close()
    }

    @Test func theWrongCAIsRefused() async throws {
        let error = await #expect(throws: DatabaseError.self) { try await DatabaseClient.connect(Self.details(ca: "other-ca.pem")) }
        #expect(error?.message == "The certificate of 127.0.0.1:3399 is not signed by the CA certificate.")
    }

    @Test func aClientCertificateLogsInAnX509Account() async throws {
        await #expect(throws: DatabaseError.self) { try await DatabaseClient.connect(Self.details(user: "quarry_x509")) }
        let client = try await DatabaseClient.connect(Self.details(user: "quarry_x509", client: true))
        let rows = try await client.run("SELECT CURRENT_USER() AS who")
        #expect(rows.string(0, "who") == "quarry_x509@127.0.0.1")
        await client.close()
    }

    @Test func overTheSocketToo() async throws {
        var details = TestServer.socketDetails
        details.useSSL = true
        let client = try await DatabaseClient.connect(details)
        #expect(client.encryption != nil)
        await client.close()
    }
}
