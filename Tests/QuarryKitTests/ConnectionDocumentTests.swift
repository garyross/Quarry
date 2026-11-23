import CommonCrypto
import CryptoKit
import Foundation
import Testing
@testable import QuarryKit

struct ConnectionDocumentTests {
    let details = ConnectionDetails(name: "Local", host: "127.0.0.1", port: "3399", user: "quarry", password: "secret",
                                    database: "quarry_demo")

    @Test func plainFileLeavesThePasswordOut() throws {
        let document = ConnectionDocument(windows: [[.init(details: details, colorIndex: 2, table: "orders",
                                                           view: "SP_VIEW_CONTENT", query: "SELECT 1")]], connectsOnOpen: true)
        let data = try document.encoded(.init(includesQuery: true), asSession: false)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret") && text.contains("SPTCPIPConnection") && !ConnectionDocument.isEncrypted(data))
        let back = try ConnectionDocument.decode(data)
        var expected = document
        expected.windows[0][0].details.password = ""
        #expect(back == expected)
    }

    @Test func passwordsNeedAFilePasswordAndAreEncrypted() throws {
        let document = ConnectionDocument(windows: [[.init(details: details)]], connectsOnOpen: false)
        #expect(throws: ConnectionDocument.FileError.passwordRequired) {
            try document.encoded(.init(includesPasswords: true), asSession: false)
        }
        let data = try document.encoded(.init(includesPasswords: true), password: "file pw", asSession: false)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret") && !text.contains("quarry_demo") && ConnectionDocument.isEncrypted(data))
        #expect(throws: ConnectionDocument.FileError.needsPassword) { try ConnectionDocument.decode(data) }
        #expect(throws: ConnectionDocument.FileError.wrongPassword) { try ConnectionDocument.decode(data, password: "nope") }
        let back = try ConnectionDocument.decode(data, password: "file pw")
        #expect(back.tabs[0].details.password == "secret" && back.tabs[0].details.database == "quarry_demo")
    }

    @Test func sessionKeepsWindowsAndTabs() throws {
        var ssh = details
        ssh.transport = .ssh
        ssh.sshHost = "bastion"
        ssh.sshPort = "2222"
        ssh.sshUser = "me"
        ssh.sshKey = "~/.ssh/id"
        var socket = details
        socket.transport = .socket
        socket.socket = "/tmp/x.sock"
        socket.host = ""
        socket.port = ""
        let document = ConnectionDocument(windows: [[.init(details: ssh, table: "a", view: "SP_VIEW_STRUCTURE")],
                                                    [.init(details: socket), .init(details: details)]], connectsOnOpen: true)
        let data = try document.encoded(.init(), asSession: true)
        let back = try ConnectionDocument.decode(data)
        #expect(back.windows.count == 2 && back.windows[1].count == 2)
        #expect(back.tabs[0].details.sshHost == "bastion" && back.tabs[0].details.sshPort == "2222"
            && back.tabs[0].details.sshKey == "~/.ssh/id" && back.tabs[0].table == "a")
        #expect(back.tabs[1].details.transport == .socket && back.tabs[1].details.socket == "/tmp/x.sock")
    }

    @Test func readsSequelProFiles() throws {
        let plain: [String: Any] = [
            "version": 1, "format": "connection", "auto_connect": true, "encrypted": false,
            "data": ["connection": ["type": "SPSocketConnection", "host": "localhost", "user": "root",
                                    "socket": "/tmp/mysql.sock", "name": "Home"],
                     "session": ["table": "users", "view": "SP_VIEW_CUSTOMQUERY", "queries": "SELECT 2"]] as [String: Any],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plain, format: .xml, options: 0)
        let document = try ConnectionDocument.decode(data)
        #expect(document.connectsOnOpen && document.tabs[0].details.transport == .socket
            && document.tabs[0].query == "SELECT 2" && SavedView.view(for: document.tabs[0].view ?? "") == "query")

        let secret: [String: Any] = ["connection": ["type": "SPTCPIPConnection", "host": "db", "user": "u", "password": "pw", "port": 3307]]
        let sealed = try #require(ConnectionDocument.sequelProEncrypt(secret, password: "open sesame"))
        let encrypted = try PropertyListSerialization.data(fromPropertyList: ["version": 1, "format": "connection",
                                                                              "encrypted": true, "data": sealed] as [String: Any],
                                                           format: .xml, options: 0)
        let opened = try ConnectionDocument.decode(encrypted, password: "open sesame")
        #expect(opened.tabs[0].details.password == "pw" && opened.tabs[0].details.port == "3307")
        #expect(throws: ConnectionDocument.FileError.wrongPassword) { try ConnectionDocument.decode(encrypted, password: "x") }
    }

    @Test func viewNames() {
        #expect(SavedView.name(for: "content") == "SP_VIEW_CONTENT" && SavedView.view(for: "SP_VIEW_RELATIONS") == "foreignKeys")
    }
}

extension ConnectionDocument {
    /// Sequel Pro's legacy scheme, to make test files Quarry must read; Quarry never writes it.
    static func sequelProEncrypt(_ dictionary: [String: Any], password: String) -> Data? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(dictionary, forKey: "data")
        archiver.finishEncoding()
        let plain = Array(archiver.encodedData)
        var padding = 16 - (plain.count + 4) % 16
        if padding < 13 { padding += 16 }
        var padded = plain + [UInt8](repeating: 0, count: padding)
        let length = UInt32(plain.count)
        padded += [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        guard padded.count % 16 == 0 else { return nil }
        let key = Array(Insecure.SHA1.hash(data: Data(password.utf8)).prefix(16))
        let iv = (0..<16).map { _ in UInt8.random(in: 0...255) }
        var out = [UInt8](repeating: 0, count: padded.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), 0, key, key.count, iv,
                             padded, padded.count, &out, out.count, &moved)
        guard status == kCCSuccess else { return nil }
        return Data(iv + out.prefix(moved))
    }
}
