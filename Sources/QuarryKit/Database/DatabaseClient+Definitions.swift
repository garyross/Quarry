import Foundation

/// Reading a view's or routine's definition for Edit View… and Edit Procedure… (S-030).
extension DatabaseClient {
    /// A view's SELECT and options, from information_schema.VIEWS and SHOW CREATE VIEW (for the algorithm).
    public func viewDefinition(_ name: String, in database: String) async throws -> ViewDefinition {
        if dialect.engine == .sqlite {
            guard let create = try await sqliteViewSQL(name), let select = DefinitionChange.viewSelect(inCreate: create) else {
                throw DatabaseError(message: "The view \u{201C}\(name)\u{201D} no longer exists.")
            }
            return ViewDefinition(name: name, algorithm: .undefined, security: .definer, checkOption: .none, select: select)
        }
        let result = try await run(
            "SELECT VIEW_DEFINITION, CHECK_OPTION, SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA = "
                + SQLQuote.mysqlLiteral(database) + " AND TABLE_NAME = " + SQLQuote.mysqlLiteral(name))
        guard !result.rows.isEmpty else { throw DatabaseError(message: "The view \u{201C}\(name)\u{201D} no longer exists.") }
        let create = try await createStatement(of: DBObject(name: name, kind: .view), in: database)
        let select = result.string(0, "VIEW_DEFINITION") ?? ""
        if select.isEmpty {
            throw DatabaseError(message: "The server doesn\u{2019}t show this view\u{2019}s definition.",
                                suggestion: "Only its definer, or a user with SHOW VIEW, can read it.")
        }
        return ViewDefinition(
            name: name,
            algorithm: DefinitionChange.algorithm(inCreate: create),
            security: result.string(0, "SECURITY_TYPE").flatMap { SQLSecurity(rawValue: $0.uppercased()) } ?? .definer,
            checkOption: result.string(0, "CHECK_OPTION").flatMap { ViewCheckOption(rawValue: $0.uppercased()) } ?? .none,
            select: select)
    }

    /// A procedure's or function's parts, and its SHOW CREATE statement (to put it back if an edit fails).
    public func routineDefinition(_ object: DBObject, in database: String) async throws -> (RoutineDefinition, statement: String) {
        let result = try await run(
            "SELECT ROUTINE_DEFINITION, DTD_IDENTIFIER, IS_DETERMINISTIC, SQL_DATA_ACCESS, SECURITY_TYPE, ROUTINE_COMMENT "
                + "FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = " + SQLQuote.mysqlLiteral(database)
                + " AND ROUTINE_NAME = " + SQLQuote.mysqlLiteral(object.name)
                + " AND ROUTINE_TYPE = " + SQLQuote.mysqlLiteral(DefinitionChange.keyword(object.kind)))
        let noun = CreateScript.noun(object.kind)
        guard !result.rows.isEmpty else { throw DatabaseError(message: "The \(noun) \u{201C}\(object.name)\u{201D} no longer exists.") }
        guard let body = result.string(0, "ROUTINE_DEFINITION") else {
            throw DatabaseError(message: "The server doesn\u{2019}t show this \(noun)\u{2019}s body.",
                                suggestion: "Only its definer, or a user who can read mysql.proc, can edit it.")
        }
        let statement = try await createStatement(of: object, in: database)
        let routine = RoutineDefinition(
            kind: object.kind,
            name: object.name,
            parameters: DefinitionChange.parameters(inCreate: statement, kind: object.kind) ?? "",
            returns: result.string(0, "DTD_IDENTIFIER") ?? "",
            deterministic: result.string(0, "IS_DETERMINISTIC")?.uppercased() == "YES",
            dataAccess: result.string(0, "SQL_DATA_ACCESS").flatMap { RoutineDataAccess(rawValue: $0.uppercased()) } ?? .containsSQL,
            security: result.string(0, "SECURITY_TYPE").flatMap { SQLSecurity(rawValue: $0.uppercased()) } ?? .definer,
            comment: result.string(0, "ROUTINE_COMMENT") ?? "",
            body: body)
        return (routine, statement)
    }
}
