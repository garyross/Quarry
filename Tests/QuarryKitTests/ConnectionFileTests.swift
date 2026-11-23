import Foundation
import Testing
@testable import QuarryKit

struct ConnectionFileTests {
    private let local = ConnectionDetails(name: "Local", host: "127.0.0.1", port: "3399", user: "quarry",
                                          password: "secret", database: "quarry_demo")
    private let socket = ConnectionDetails(name: "Sock", transport: .socket, socket: "/tmp/x.sock", user: "root",
                                           password: "pw", useSSL: true, sslCA: "~/ca.pem")
    private let tunnel = ConnectionDetails(name: "Staging", transport: .ssh, host: "127.0.0.1", port: "3306",
                                           user: "deploy", password: "pw", sshHost: "bastion", sshPort: "2222",
                                           sshUser: "me", sshPassword: "ssh-secret", sshKey: "~/.ssh/id_ed25519")

    @Test func roundTripKeepsEverythingButPasswords() throws {
        let entries = [
            ConnectionFile.Entry(details: local, colorIndex: 0),
            ConnectionFile.Entry(group: "Work", details: socket, colorIndex: 4),
            ConnectionFile.Entry(group: "Work", details: tunnel),
        ]
        let data = try ConnectionFile.encode(entries, groups: ["Work", "Empty"])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret"))
        #expect(!text.contains(">pw<"))
        let (decoded, groups) = try ConnectionFile.decode(data)
        #expect(groups == ["Work", "Empty"])
        #expect(decoded == entries)
        #expect(decoded.allSatisfy { $0.details.password.isEmpty && $0.details.sshPassword.isEmpty })
        #expect(decoded[1].details.useSSL && decoded[1].details.sslCA == "~/ca.pem")
        #expect(decoded[2].details.sshKey == "~/.ssh/id_ed25519" && decoded[2].details.sshPort == "2222")
    }

    @Test func writesSequelProsKeys() throws {
        let data = try ConnectionFile.encode([ConnectionFile.Entry(group: "Work", details: tunnel, colorIndex: 2)])
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let top = try #require(plist["SPConnectionFavorites"] as? [[String: Any]])
        #expect(top.first?["Name"] as? String == "Work")
        let child = try #require((top.first?["Children"] as? [[String: Any]])?.first)
        #expect(child["type"] as? Int == 2)
        #expect(child["colorIndex"] as? Int == 2)
        #expect(child["sshKeyLocationEnabled"] as? Int == 1)
        #expect(child["password"] == nil)
    }

    @Test func readsASequelProExportWithNestedGroupsAndTheRoot() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>SPConnectionFavorites</key><array>
        <dict><key>Name</key><string>Favorites</string><key>IsExpanded</key><true/><key>Children</key><array>
          <dict><key>name</key><string>Prod</string><key>host</key><string>db.example.com</string>
            <key>port</key><integer>3307</integer><key>type</key><integer>0</integer>
            <key>colorIndex</key><integer>9</integer><key>user</key><string>admin</string></dict>
          <dict><key>Name</key><string>Clients</string><key>Children</key><array>
            <dict><key>Name</key><string>Acme</string><key>Children</key><array>
              <dict><key>name</key><string>Acme DB</string><key>type</key><integer>1</integer>
                <key>socket</key><string>/tmp/acme.sock</string><key>colorIndex</key><integer>3</integer>
                <key>sslKeyFileLocationEnabled</key><integer>0</integer>
                <key>sslKeyFileLocation</key><string>/unused.pem</string></dict>
            </array></dict>
          </array></dict>
        </array></dict>
        </array></dict></plist>
        """
        let (entries, groups) = try ConnectionFile.decode(Data(xml.utf8))
        #expect(groups == ["Clients", "Clients / Acme"])
        #expect(entries.count == 2)
        #expect(entries[0].group == "" && entries[0].details.port == "3307" && entries[0].colorIndex == -1)
        #expect(entries[1].group == "Clients / Acme" && entries[1].details.transport == .socket)
        #expect(entries[1].colorIndex == 3 && entries[1].details.sslKey.isEmpty)
    }

    @Test func aFileWithNoConnectionsSaysSo() {
        #expect(throws: ConnectionFile.ImportError.noConnections) { try ConnectionFile.decode(Data("nope".utf8)) }
        let empty = try! PropertyListSerialization.data(fromPropertyList: ["SPConnectionFavorites": [Any]()],
                                                         format: .xml, options: 0)
        #expect(throws: ConnectionFile.ImportError.noConnections) { try ConnectionFile.decode(empty) }
    }

    @Test func summariesAndNames() {
        #expect(ConnectionFile.summary(connections: 3, groups: 1) == "Imported 3 connections in 1 group.")
        #expect(ConnectionFile.summary(connections: 1, groups: 0) == "Imported 1 connection.")
        #expect(ConnectionFile.newGroupName(after: ["New Group", "New Group 2"]) == "New Group 3")
        #expect(ConnectionFile.copyName(of: "Local", among: ["Local"]) == "Local Copy")
        #expect(ConnectionFile.copyName(of: "Local", among: ["Local Copy"]) == "Local Copy 2")
    }

    @Test func ordersByEachKey() {
        let items = [
            ConnectionOrder.Item(name: "b", host: "z", transport: .ssh, colorIndex: -1, order: 0),
            ConnectionOrder.Item(name: "a", host: "y", transport: .tcp, colorIndex: 4, order: 1),
            ConnectionOrder.Item(name: "c", host: "x", transport: .socket, colorIndex: 0, order: 2),
        ]
        #expect(ConnectionOrder.manual.sorted(items) == [0, 1, 2])
        #expect(ConnectionOrder.name.sorted(items) == [1, 0, 2])
        #expect(ConnectionOrder.name.sorted(items, reversed: true) == [2, 0, 1])
        #expect(ConnectionOrder.host.sorted(items) == [2, 1, 0])
        #expect(ConnectionOrder.type.sorted(items) == [1, 2, 0])
        #expect(ConnectionOrder.color.sorted(items) == [2, 1, 0])
    }
}
