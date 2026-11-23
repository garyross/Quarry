import Foundation
import QuarryKit

/// Self-test: SSL connections (S-058), with the certificates tools/testdb.sh makes.
extension SelfTest {
    static let testSSLFolder = NSHomeDirectory() + "/Library/Developer/Quarry/test-db/ssl/"

    static var sslDetails: ConnectionDetails {
        ConnectionDetails(name: "Local SSL", host: "127.0.0.1", port: "3399", user: "quarry", password: "quarry",
                          database: "quarry_demo", useSSL: true, sslCA: testSSLFolder + "ca.pem")
    }

    static func ssl(model: AppModel, session: Session) async {
        guard FileManager.default.fileExists(atPath: testSSLFolder + "ca.pem") else {
            check("S-058 the test server has certificates (tools/testdb.sh reset, then start)", false)
            return
        }
        let local = session.selectedSaved
        session.disconnect()
        let uid = model.save(sslDetails, over: nil)
        session.show(saved: model.savedConnection(uid))
        check("S-058 a saved connection keeps its SSL files", session.form == sslDetails)

        await session.testConnection()
        if case .success(let text) = session.testResult {
            check("S-058 Test Connection says it used SSL", text.contains("with SSL (TLSv"), text)
        } else {
            check("S-058 Test Connection says it used SSL", false, String(describing: session.testResult))
        }

        session.connect(model: model)
        await session.waitForConnect()
        check("S-058 connects with SSL, checked against the CA",
              session.phase == .connected && session.encryption?.serverChecked == true, session.connectProblem?.message ?? "")
        check("S-058 the window subtitle says SSL", session.subtitle == "quarry_demo · Local SSL · SSL", session.subtitle)
        if let client = session.client {
            let rows = try? await client.run("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
            check("S-058 the server agrees the session is encrypted", rows?.string(0, "Value")?.isEmpty == false)
        }
        session.disconnect()

        // The wrong CA: refused, with the reason under the form.
        var wrongCA = sslDetails
        wrongCA.sslCA = testSSLFolder + "other-ca.pem"
        session.form = wrongCA
        session.connect(model: model)
        await session.waitForConnect()
        check("S-058 a server certificate the CA didn't sign is refused",
              session.phase != .connected
                && session.connectProblem?.message == "The certificate of 127.0.0.1:3399 is not signed by the CA certificate.",
              session.connectProblem?.message ?? "connected")

        // A key without its certificate is caught before connecting.
        var keyOnly = sslDetails
        keyOnly.sslKey = testSSLFolder + "client-key.pem"
        session.form = keyOnly
        session.connect(model: model)
        await session.waitForConnect()
        check("S-058 a key file needs its certificate",
              session.connectProblem?.message == "Choose the certificate for the key file.", session.connectProblem?.message ?? "")

        // An account created REQUIRE X509 logs in with the client certificate.
        var x509 = sslDetails
        x509.user = "quarry_x509"
        x509.sslKey = testSSLFolder + "client-key.pem"
        x509.sslCertificate = testSSLFolder + "client-cert.pem"
        session.form = x509
        session.connect(model: model)
        await session.waitForConnect()
        check("S-058 a client certificate logs in an X509 account", session.phase == .connected, session.connectProblem?.message ?? "")
        session.disconnect()

        model.delete(uid)
        session.show(saved: model.savedConnection(local))
        session.connect(model: model)
        await session.waitForConnect()
        check("S-058 a connection without SSL is not encrypted", session.phase == .connected && session.encryption == nil)
    }
}
