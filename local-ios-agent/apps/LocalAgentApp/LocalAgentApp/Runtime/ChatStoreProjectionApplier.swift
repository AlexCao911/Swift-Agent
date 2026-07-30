import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import SQLite3

enum TranscriptProjectionApplyResult: Equatable {
    case applied
    case duplicate
    case gap(expected: UInt64, received: UInt64)
}

struct TranscriptProjectionStoreError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

final class TranscriptProjectionStore {
    private var database: OpaquePointer?

    init(fileURL: URL?) throws {
        let path = fileURL?.path ?? ":memory:"
        guard sqlite3_open_v2(
            path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw failure("could not open the transcript projection store")
        }
        try execute("PRAGMA foreign_keys = ON")
        try execute("""
            CREATE TABLE IF NOT EXISTS rust_projection_cursor (
                conversation_stream_id TEXT PRIMARY KEY,
                last_sequence INTEGER NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS rust_projection_event (
                conversation_stream_id TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                event_json BLOB NOT NULL,
                PRIMARY KEY (conversation_stream_id, sequence)
            )
            """)
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func cursor(for streamID: String) throws -> UInt64 {
        let rows = try query(
            "SELECT last_sequence FROM rust_projection_cursor WHERE conversation_stream_id = ?",
            bindings: [.text(streamID)]
        )
        return rows.first.flatMap(UInt64.init) ?? 0
    }

    func persist(
        _ event: TranscriptProjectionEventDTO
    ) throws -> TranscriptProjectionApplyResult {
        try execute("BEGIN IMMEDIATE")
        do {
            let current = try cursor(for: event.conversationStreamID)
            if event.sequence <= current {
                try execute("COMMIT")
                return .duplicate
            }
            let expected = current + 1
            guard event.sequence == expected else {
                try execute("ROLLBACK")
                return .gap(expected: expected, received: event.sequence)
            }
            try execute(
                """
                INSERT INTO rust_projection_event (
                    conversation_stream_id, sequence, event_json
                ) VALUES (?, ?, ?)
                """,
                bindings: [
                    .text(event.conversationStreamID),
                    .integer(event.sequence),
                    .blob(try JSONEncoder().encode(event)),
                ]
            )
            try execute(
                """
                INSERT INTO rust_projection_cursor (
                    conversation_stream_id, last_sequence
                ) VALUES (?, ?)
                ON CONFLICT(conversation_stream_id) DO UPDATE SET
                    last_sequence = excluded.last_sequence
                """,
                bindings: [
                    .text(event.conversationStreamID),
                    .integer(event.sequence),
                ]
            )
            try execute("COMMIT")
            return .applied
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func events(for streamID: String) throws -> [TranscriptProjectionEventDTO] {
        var statement: OpaquePointer?
        guard let database,
              sqlite3_prepare_v2(
                  database,
                  """
                  SELECT event_json
                  FROM rust_projection_event
                  WHERE conversation_stream_id = ?
                  ORDER BY sequence
                  """,
                  -1,
                  &statement,
                  nil
              ) == SQLITE_OK,
              let statement
        else {
            throw failure("could not prepare projection replay")
        }
        defer { sqlite3_finalize(statement) }
        try bind(.text(streamID), to: statement, index: 1)

        var events: [TranscriptProjectionEventDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard let bytes = sqlite3_column_blob(statement, 0) else {
                throw failure("stored projection event is empty")
            }
            let data = Data(bytes: bytes, count: count)
            events.append(try JSONDecoder().decode(
                TranscriptProjectionEventDTO.self,
                from: data
            ))
        }
        return events
    }

    private enum Binding {
        case text(String)
        case integer(UInt64)
        case blob(Data)
    }

    private func execute(
        _ sql: String,
        bindings: [Binding] = []
    ) throws {
        var statement: OpaquePointer?
        guard let database,
              sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw failure("could not prepare projection statement")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            try bind(value, to: statement, index: Int32(offset + 1))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw failure("could not write transcript projection")
        }
    }

    private func query(
        _ sql: String,
        bindings: [Binding]
    ) throws -> [String] {
        var statement: OpaquePointer?
        guard let database,
              sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw failure("could not prepare projection query")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            try bind(value, to: statement, index: Int32(offset + 1))
        }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
        return values
    }

    private func bind(
        _ value: Binding,
        to statement: OpaquePointer,
        index: Int32
    ) throws {
        let result: Int32
        switch value {
        case let .text(text):
            result = text.withCString {
                sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
            }
        case let .integer(value):
            guard value <= UInt64(Int64.max) else {
                throw failure("projection sequence exceeds SQLite integer range")
            }
            result = sqlite3_bind_int64(statement, index, Int64(value))
        case let .blob(data):
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
        guard result == SQLITE_OK else {
            throw failure("could not bind projection value")
        }
    }

    private func failure(_ fallback: String) -> TranscriptProjectionStoreError {
        TranscriptProjectionStoreError(
            message: database.map { String(cString: sqlite3_errmsg($0)) }
                ?? fallback
        )
    }
}

@MainActor
final class ChatStoreProjectionApplier {
    private let store: ChatStore
    private let persistence: TranscriptProjectionStore

    init(
        store: ChatStore,
        persistence: TranscriptProjectionStore
    ) {
        self.store = store
        self.persistence = persistence
    }

    func cursor(for streamID: String) throws -> UInt64 {
        try persistence.cursor(for: streamID)
    }

    func replay(conversationStreamID: String) throws {
        store.resetProjection(conversationStreamID: conversationStreamID)
        for event in try persistence.events(for: conversationStreamID) {
            store.applyProjection(event)
        }
    }

    func restoreSessions(_ summaries: [ConversationSummaryDTO]) {
        store.restoreSessions(summaries)
    }

    func apply(
        _ event: TranscriptProjectionEventDTO
    ) throws -> TranscriptProjectionApplyResult {
        let result = try persistence.persist(event)
        if result == .applied {
            store.applyProjection(event)
        }
        return result
    }

    func applyTransient(_ event: TranscriptProjectionEventDTO) {
        store.applyProjection(event)
    }
}

private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
