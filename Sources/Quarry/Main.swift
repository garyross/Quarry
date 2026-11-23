import Foundation

/// `Quarry mcp` runs the MCP bridge for an agent (S-063); anything else opens the app.
@main
enum Main {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "mcp" {
            exit(MCPBridge.run(socketPath: MCPHost.socketPath))
        }
        QuarryApp.main()
    }
}
