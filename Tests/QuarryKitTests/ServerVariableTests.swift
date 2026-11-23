import Testing
@testable import QuarryKit

struct ServerVariableTests {
    let variables = [
        ServerVariable(name: "innodb_buffer_pool_size", value: "134217728"),
        ServerVariable(name: "key_buffer_size", value: "134217728"),
        ServerVariable(name: "version", value: "13.0.2-MariaDB"),
    ]

    @Test func filterMatchesNameOrValueIgnoringCase() {
        #expect(ServerVariable.filter(variables, "BUFFER").map(\.name) == ["innodb_buffer_pool_size", "key_buffer_size"])
        #expect(ServerVariable.filter(variables, "mariadb").map(\.name) == ["version"])
        #expect(ServerVariable.filter(variables, "  ").count == 3)
    }

    @Test func copyAndSaveText() {
        let two = Array(variables.suffix(2))
        #expect(ServerVariable.copyText(two, .both) == "key_buffer_size = 134217728\nversion = 13.0.2-MariaDB")
        #expect(ServerVariable.copyText(two, .name) == "key_buffer_size\nversion")
        #expect(ServerVariable.copyText(two, .value) == "134217728\n13.0.2-MariaDB")
        #expect(ServerVariable.cnfText(two, server: "Local") ==
            "# Server variables for Local\n\nkey_buffer_size = 134217728\nversion = 13.0.2-MariaDB\n")
    }

    @Test func counts() {
        #expect(ServerVariable.countText(shown: 12, total: 1640, filtering: true) == "12 of 1,640")
        #expect(ServerVariable.countText(shown: 640, total: 640, filtering: false) == "640 variables")
    }
}
