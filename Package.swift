// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Quarry",
    platforms: [.macOS(.v26)],
    dependencies: [
        // MySQL/MariaDB wire protocol in pure Swift (no libmysqlclient).
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.0"),
        // TLS for SSL connections (S-058); mysql-nio already uses it.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
        // The MCP server's HTTP endpoint and Unix socket (S-063); mysql-nio already uses NIO.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
    ],
    targets: [
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(
            name: "QuarryKit",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]
        ),
        // The window's controllers and sheet drafts: observable, on the main
        // actor, no SwiftUI or AppKit, so tests reach them (review 2026-11-20).
        .target(
            name: "QuarryControllers",
            dependencies: ["QuarryKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(
            name: "Quarry",
            dependencies: ["QuarryKit", "QuarryControllers"],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // What both test targets share: the test server's address.
        .target(name: "QuarryTestSupport", dependencies: ["QuarryKit"], path: "Tests/Support"),
        .testTarget(name: "QuarryKitTests", dependencies: ["QuarryKit", "QuarryTestSupport"]),
        // The controllers through their own interface, on a SQLite file (and the
        // test server when it runs), with no window.
        .testTarget(
            name: "QuarryControllersTests",
            dependencies: ["QuarryKit", "QuarryControllers", "QuarryTestSupport"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
