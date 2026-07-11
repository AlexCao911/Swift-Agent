import CSQLite
import Foundation

package struct SQLiteStoreError: Error, Equatable, Sendable {
    package let code: String
    package let message: String
}

package enum SQLiteValue {
    case text(String)
    case integer(Int64)
    case blob(Data)
    case null
}

package struct SQLiteRow: Sendable {
    private let values: [String: SQLiteColumnValue]

    fileprivate init(values: [String: SQLiteColumnValue]) {
        self.values = values
    }

    package func text(_ column: String) -> String? {
        guard case let .text(value) = values[column] else { return nil }
        return value
    }

    package func integer(_ column: String) -> Int64? {
        guard case let .integer(value) = values[column] else { return nil }
        return value
    }

    package func blob(_ column: String) -> Data? {
        guard case let .blob(value) = values[column] else { return nil }
        return value
    }

    package func isNull(_ column: String) -> Bool {
        guard let value = values[column] else { return true }
        if case .null = value { return true }
        return false
    }
}

private enum SQLiteColumnValue: Sendable {
    case text(String)
    case integer(Int64)
    case blob(Data)
    case null
}

package final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?

    package init(path: String) throws {
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

    package func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw error("llm_store.sqlite_execute")
        }
    }

    package func executeChanges(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int {
        try execute(sql, bindings: bindings)
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    package func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[String: String?]] {
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

    package func queryRows(_ sql: String, bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [SQLiteRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var values: [String: SQLiteColumnValue] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_NULL:
                        values[name] = .null
                    case SQLITE_INTEGER:
                        values[name] = .integer(sqlite3_column_int64(statement, index))
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, index))
                        if count == 0 {
                            values[name] = .blob(Data())
                        } else if let bytes = sqlite3_column_blob(statement, index) {
                            values[name] = .blob(Data(bytes: bytes, count: count))
                        }
                    default:
                        if let text = sqlite3_column_text(statement, index) {
                            values[name] = .text(String(cString: text))
                        }
                    }
                }
                rows.append(SQLiteRow(values: values))
            case SQLITE_DONE:
                return rows
            default:
                throw error("llm_store.sqlite_query")
            }
        }
    }

    package func transaction<T>(_ operation: () throws -> T) throws -> T {
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
                case let .integer(value):
                    result = sqlite3_bind_int64(statement, index, value)
                case let .blob(data):
                    if data.isEmpty {
                        result = sqlite3_bind_zeroblob(statement, index, 0)
                    } else {
                        result = data.withUnsafeBytes { bytes in
                            sqlite3_bind_blob(
                                statement,
                                index,
                                bytes.baseAddress,
                                Int32(bytes.count),
                                sqliteTransient
                            )
                        }
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
