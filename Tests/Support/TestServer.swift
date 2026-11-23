import Foundation
import QuarryKit

/// The private test MariaDB on 127.0.0.1:3399 (tools/testdb.sh), never the owner's server.
public enum TestServer {
    public static let details = ConnectionDetails(name: "Test", host: "127.0.0.1", port: "3399", user: "quarry",
                                           password: "quarry", database: "quarry_demo")
    public static let socketDetails = ConnectionDetails(name: "Test", transport: .socket,
                                                 socket: NSHomeDirectory() + "/Library/Developer/Quarry/test-db/mysqld.sock",
                                                 user: "quarry", password: "quarry", database: "quarry_demo")

    /// True when something listens on 127.0.0.1:3399.
    public static var isRunning: Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(3399).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
