import AppKit
import QuarryKit

/// Self-test: Database > View Using Encoding (S-056).
extension SelfTest {
    static func viewEncoding(session: Session) async {
        guard let client = session.client else { return check("S-056 connected", false) }
        let table = "`quarry_legacy`.`quarry_selftest_mixed`"
        _ = try? await client.run("DROP TABLE IF EXISTS \(table)")
        _ = try? await client.run("CREATE TABLE \(table) (id INT PRIMARY KEY, body VARCHAR(40)) CHARACTER SET latin1")
        // Row 1 is latin1 stored properly; row 2 is UTF-8 bytes stored as latin1, the usual mix-up.
        _ = try? await client.run("INSERT INTO \(table) VALUES (1, 'Café'), (2, CONVERT(UNHEX('436166C3A9') USING latin1))")
        func bodies() async -> [String] {
            ((try? await client.run("SELECT body FROM \(table) ORDER BY id"))?.rows ?? []).map { $0[0].plainText ?? "" }
        }
        let start = await bodies()
        check("S-056 on UTF-8, latin1 text reads right and the mixed-up row shows its mix-up",
              start == ["Café", "CafÃ©"], "\(start)")

        await session.setViewEncoding(.utf8ViaLatin1)?.value
        let via = await bodies()
        check("S-056 UTF-8 Unicode via Latin 1 shows the mixed-up row correctly",
              session.viewEncoding == .utf8ViaLatin1 && via.last == "Café", "\(via)")
        let item = menuItem(ViewEncoding.utf8ViaLatin1.title)
        check("S-056 the menu checks the encoding in use", item?.state == .on, "\(item?.state.rawValue ?? -1)")

        await session.setViewEncoding(.latin1)?.value
        let latin = await bodies()
        check("S-056 ISO Latin 1 reads latin1 bytes as latin1", latin.first == "Café", "\(latin)")
        let refused = try? await client.run("SELECT 'é'")
        check("S-056 a statement with non-ASCII text is refused outside UTF-8 modes, not garbled", refused == nil)

        await session.setViewEncoding(.utf8mb4)?.value
        check("S-056 back on UTF-8, it reads as before", await bodies() == start)
        _ = try? await client.run("DROP TABLE IF EXISTS \(table)")
    }
}
