import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import LocalAgentLLMCore

public struct HostToolEffectError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct HostToolEffectPreparation: Sendable {
    public let effectID: String
    public let shouldExecute: Bool
    public let replayResult: ToolResultDTO?

    fileprivate let runID: String
    fileprivate let generationTurnID: String
    fileprivate let callID: String
    fileprivate let toolName: String
}

public actor HostToolEffectLedger {
    private let database: SQLiteConnection

    public init(fileURL: URL?) throws {
        database = try SQLiteConnection(path: fileURL?.path ?? ":memory:")
        try database.execute(
            """
            create table if not exists host_tool_effects (
              effect_id text primary key,
              run_id text not null,
              generation_turn_id text not null,
              call_id text not null,
              tool_name text not null,
              state text not null check(state in ('prepared', 'committed', 'outcome_unknown')),
              result_digest text,
              replay_json text
            )
            """
        )
        try database.execute(
            "update host_tool_effects set state = 'outcome_unknown' where state = 'prepared'"
        )
    }

    public func prepare(
        _ request: ToolExecutionRequestDTO,
        generationTurnID: String
    ) throws -> HostToolEffectPreparation {
        let effectID = Self.effectID(
            runID: request.runId,
            callID: request.toolCallId,
            toolName: request.toolName
        )
        let rows = try database.query(
            """
            select state, replay_json from host_tool_effects where effect_id = ?
            """,
            bindings: [.text(effectID)]
        )
        if let row = rows.first {
            switch row["state"] ?? nil {
            case "committed":
                guard let json = row["replay_json"] ?? nil,
                      let data = json.data(using: .utf8),
                      let result = try? JSONDecoder().decode(
                          ToolResultDTO.self,
                          from: data
                      )
                else {
                    throw failure(
                        "host_tool_effect.replay_invalid",
                        "committed tool effect has no safe replay result"
                    )
                }
                return preparation(
                    request,
                    generationTurnID: generationTurnID,
                    effectID: effectID,
                    shouldExecute: false,
                    replayResult: result
                )
            case "prepared", "outcome_unknown":
                throw failure(
                    "host_tool_effect.outcome_unknown",
                    "tool effect may already have executed and cannot be repeated automatically"
                )
            default:
                throw failure(
                    "host_tool_effect.state_invalid",
                    "tool effect has an unknown durable state"
                )
            }
        }

        try database.execute(
            """
            insert into host_tool_effects(
              effect_id, run_id, generation_turn_id, call_id, tool_name, state
            ) values (?, ?, ?, ?, ?, 'prepared')
            """,
            bindings: [
                .text(effectID),
                .text(request.runId),
                .text(generationTurnID),
                .text(request.toolCallId),
                .text(request.toolName),
            ]
        )
        return preparation(
            request,
            generationTurnID: generationTurnID,
            effectID: effectID,
            shouldExecute: true,
            replayResult: nil
        )
    }

    public func commit(
        _ preparation: HostToolEffectPreparation,
        result: ToolResultDTO
    ) throws {
        guard preparation.shouldExecute else { return }
        let completedAt = Self.timestamp(Date())
        let normalizedResult = try JSONDecoder().decode(
            CanonicalJSONValue.self,
            from: Data(result.structuredJson.utf8)
        )
        let document = try CanonicalJSONValue.object(entries: [
            .init(name: "schema_version", value: .string("1")),
            .init(name: "effect_id", value: .string(preparation.effectID)),
            .init(name: "run_id", value: .string(preparation.runID)),
            .init(
                name: "generation_turn_id",
                value: .string(preparation.generationTurnID)
            ),
            .init(name: "call_id", value: .string(preparation.callID)),
            .init(name: "tool_name", value: .string(preparation.toolName)),
            .init(name: "normalized_result", value: normalizedResult),
            .init(name: "is_error", value: .bool(result.isError)),
            .init(name: "replay_class", value: .string("safe_result")),
            .init(name: "completed_at", value: .string(completedAt)),
        ])
        let digest = try CanonicalDigestV1.digest(
            domain: "host-tool-effect-result:v1",
            document: document
        ).hex
        let replayJSON = String(
            decoding: try JSONEncoder().encode(result),
            as: UTF8.self
        )
        let changed = try database.executeChanges(
            """
            update host_tool_effects
               set state = 'committed', result_digest = ?, replay_json = ?
             where effect_id = ? and state = 'prepared'
            """,
            bindings: [
                .text(digest),
                .text(replayJSON),
                .text(preparation.effectID),
            ]
        )
        guard changed == 1 else {
            throw failure(
                "host_tool_effect.commit_conflict",
                "tool effect is no longer in the prepared state"
            )
        }
    }

    public static func effectID(
        runID: String,
        callID: String,
        toolName: String
    ) -> String {
        "\(runID):\(callID):\(toolName)"
    }

    private func preparation(
        _ request: ToolExecutionRequestDTO,
        generationTurnID: String,
        effectID: String,
        shouldExecute: Bool,
        replayResult: ToolResultDTO?
    ) -> HostToolEffectPreparation {
        HostToolEffectPreparation(
            effectID: effectID,
            shouldExecute: shouldExecute,
            replayResult: replayResult,
            runID: request.runId,
            generationTurnID: generationTurnID,
            callID: request.toolCallId,
            toolName: request.toolName
        )
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }

    private func failure(_ code: String, _ message: String) -> HostToolEffectError {
        HostToolEffectError(code: code, message: message)
    }
}
