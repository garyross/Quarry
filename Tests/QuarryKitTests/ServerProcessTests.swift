import Testing
@testable import QuarryKit

struct ServerProcessTests {
    @Test func readsTheProcessList() {
        let result = StatementResult(
            sql: "", columns: ["Id", "User", "Host", "db", "Command", "Time", "State", "Info", "Progress"].map { ResultColumn(name: $0) },
            rows: [
                [.text("5"), .text("quarry"), .text("127.0.0.1:5123"), .text("quarry_demo"), .text("Query"), .text("12"),
                 .text("User sleep"), .text("SELECT SLEEP(30)"), .text("0.000")],
                [.text("6"), .text("app"), .text("localhost"), .null, .text("Sleep"), .text("3"), .text(""), .null, .text("0.000")],
            ],
            affectedRows: nil, duration: .zero)
        let processes = ServerProcess.processes(result)
        #expect(processes.map(\.id) == [5, 6])
        #expect(processes[0].isRunning && !processes[1].isRunning)
        #expect(processes[1].database == nil && processes[1].info == nil && processes[0].time == 12)
        #expect(ServerProcess.filter(processes, "sleep(").map(\.id) == [5])
        #expect(ServerProcess.filter(processes, "LOCALHOST").map(\.id) == [6])
        #expect(ServerProcess.filter(processes, "").count == 2)
    }

    @Test func textAndKill() {
        let process = ServerProcess(id: 7, user: "a", host: "h", database: "d", command: "Query", time: 1, state: "s",
                                    info: "SELECT\t1\nFROM t")
        #expect(ServerProcess.text([process]) == "ID\tUser\tHost\tDatabase\tCommand\tTime\tState\tInfo\n7\ta\th\td\tQuery\t1\ts\tSELECT 1 FROM t\n")
        #expect(ServerProcess.killSQL(7, connection: false) == "KILL QUERY 7")
        #expect(ServerProcess.killSQL(7, connection: true) == "KILL CONNECTION 7")
    }
}
