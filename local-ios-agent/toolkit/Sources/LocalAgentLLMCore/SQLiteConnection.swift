import CSQLite
import Foundation

struct SQLiteStoreError: Error, Equatable, Sendable {
    let code: String
    let message: String
}

enum SQLiteValue {
    case text(String)
    case null
}

final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite open returned no database handle"
            if let database { sqlite3_close(database) }
            throw SQLiteStoreError(code: "llm_store.sqlite_open", message: message)
        }
        handle = database
        try execute("PRAGMA foreign_keys = ON")
        guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else {
            throw error("llm_store.sqlite_busy_timeout")
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw error("llm_store.sqlite_execute")
        }
    }

    func executeChanges(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int {
        try execute(sql, bindings: bindings)
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[String: String?]] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String?]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var row: [String: String?] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    if sqlite3_column_type(statement, index) == SQLITE_NULL {
                        row[name] = .some(nil)
                    } else if let text = sqlite3_column_text(statement, index) {
                        row[name] = String(cString: text)
                    }
                }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                throw error("llm_store.sqlite_query")
            }
        }
    }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try operation()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, bindings: [SQLiteValue]) throws -> OpaquePointer {
        guard let handle else {
            throw SQLiteStoreError(
                code: "llm_store.sqlite_closed",
                message: "SQLite connection is closed"
            )
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw error("llm_store.sqlite_prepare")
        }
        do {
            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case let .text(text):
                    result = text.withCString { pointer in
                        sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
                    }
                case .null:
                    result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else {
                    throw error("llm_store.sqlite_bind")
                }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func error(_ code: String) -> SQLiteStoreError {
        SQLiteStoreError(
            code: code,
            message: handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite connection is closed"
        )
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
