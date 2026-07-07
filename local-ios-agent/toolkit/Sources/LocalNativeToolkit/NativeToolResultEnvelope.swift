import Foundation
import LocalAgentBridge

public struct ToolResultEnvelopeV1: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var manifestId: String
    public var toolName: String
    public var toolCallId: String
    public var result: [String: JSONValue]
    public var provenance: Provenance
    public var contextPolicy: ContextPolicy
    public var audit: Audit

    public struct Provenance: Codable, Sendable, Equatable {
        public var sourceKind: String
        public var sourceId: String
        public var displayName: String
        public var attachmentIds: [String]
        public var trustLevel: NativeToolTrustLevel
        public var sensitivity: SensitivityDTO
        public var retention: RetentionPolicyDTO

        private enum CodingKeys: String, CodingKey {
            case sourceKind = "source_kind"
            case sourceId = "source_id"
            case displayName = "display_name"
            case attachmentIds = "attachment_ids"
            case trustLevel = "trust_level"
            case sensitivity
            case retention
        }
    }

    public struct ContextPolicy: Codable, Sendable, Equatable {
        public var modelTextPolicy: String
        public var trustLevel: NativeToolTrustLevel
        public var sourceLabel: String

        private enum CodingKeys: String, CodingKey {
            case modelTextPolicy = "model_text_policy"
            case trustLevel = "trust_level"
            case sourceLabel = "source_label"
        }
    }

    public struct Audit: Codable, Sendable, Equatable {
        public var summary: String
        public var redaction: String
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case manifestId = "manifest_id"
        case toolName = "tool_name"
        case toolCallId = "tool_call_id"
        case result
        case provenance
        case contextPolicy = "context_policy"
        case audit
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unsupported JSON value"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public enum NativeToolResultBuilder {
    public static func success(
        manifestId: String,
        toolName: String,
        toolCallId: String,
        displayText: String,
        modelText: String,
        resultKind: String,
        resultPayload: [String: JSONValue],
        sourceKind: String,
        sourceId: String,
        displayName: String,
        attachmentIds: [String],
        trustLevel: NativeToolTrustLevel,
        sensitivity: SensitivityDTO,
        retention: RetentionPolicyDTO,
        modelTextPolicy: String,
        sourceLabel: String,
        auditSummary: String,
        auditRedaction: String
    ) -> ToolResultDTO {
        var result = resultPayload
        result["kind"] = .string(resultKind)
        let envelope = ToolResultEnvelopeV1(
            schemaVersion: 1,
            manifestId: manifestId,
            toolName: toolName,
            toolCallId: toolCallId,
            result: result,
            provenance: ToolResultEnvelopeV1.Provenance(
                sourceKind: sourceKind,
                sourceId: sourceId,
                displayName: displayName,
                attachmentIds: attachmentIds,
                trustLevel: trustLevel,
                sensitivity: sensitivity,
                retention: retention
            ),
            contextPolicy: ToolResultEnvelopeV1.ContextPolicy(
                modelTextPolicy: modelTextPolicy,
                trustLevel: trustLevel,
                sourceLabel: sourceLabel
            ),
            audit: ToolResultEnvelopeV1.Audit(
                summary: auditSummary,
                redaction: auditRedaction
            )
        )
        return ToolResultDTO(
            displayText: displayText,
            modelText: modelText,
            structuredJson: encode(envelope),
            auditText: auditSummary,
            sensitivity: sensitivity,
            retention: retention,
            isError: false
        )
    }

    public static func error(
        manifestId: String,
        toolName: String,
        toolCallId: String,
        code: String,
        displayText: String,
        auditSummary: String
    ) -> ToolResultDTO {
        success(
            manifestId: manifestId,
            toolName: toolName,
            toolCallId: toolCallId,
            displayText: displayText,
            modelText: "Tool error `\(code)`: \(displayText)",
            resultKind: "error",
            resultPayload: ["code": .string(code)],
            sourceKind: "tool",
            sourceId: toolName,
            displayName: toolName,
            attachmentIds: [],
            trustLevel: .trustedToolResult,
            sensitivity: .public,
            retention: .runOnly,
            modelTextPolicy: "error_summary_only",
            sourceLabel: "Tool",
            auditSummary: auditSummary,
            auditRedaction: "metadata_only"
        ).withErrorFlag()
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(value)
            return String(decoding: data, as: UTF8.self)
        } catch {
            return #"{"result":{"kind":"encoding_failed"},"schema_version":1}"#
        }
    }
}

private extension ToolResultDTO {
    func withErrorFlag() -> ToolResultDTO {
        ToolResultDTO(
            displayText: displayText,
            modelText: modelText,
            structuredJson: structuredJson,
            auditText: auditText,
            sensitivity: sensitivity,
            retention: retention,
            isError: true
        )
    }
}

public enum NativeToolResultEnvelopeValidationError: Error, Equatable {
    case invalidStructuredJson
    case isErrorMismatch
    case retentionMismatch
}

public enum NativeToolResultEnvelopeValidator {
    public static func validate(_ result: ToolResultDTO) throws -> ToolResultDTO {
        guard let data = result.structuredJson.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ToolResultEnvelopeV1.self, from: data)
        else {
            throw NativeToolResultEnvelopeValidationError.invalidStructuredJson
        }
        let envelopeIsError = envelope.result["kind"] == .string("error")
        guard envelopeIsError == result.isError else {
            throw NativeToolResultEnvelopeValidationError.isErrorMismatch
        }
        guard envelope.provenance.retention == result.retention else {
            throw NativeToolResultEnvelopeValidationError.retentionMismatch
        }
        return ToolResultDTO(
            displayText: result.displayText,
            modelText: result.modelText,
            structuredJson: result.structuredJson,
            auditText: result.auditText,
            sensitivity: moreSensitive(result.sensitivity, envelope.provenance.sensitivity),
            retention: result.retention,
            isError: result.isError
        )
    }

    private static func moreSensitive(_ lhs: SensitivityDTO, _ rhs: SensitivityDTO) -> SensitivityDTO {
        sensitivityRank(rhs) >= sensitivityRank(lhs) ? rhs : lhs
    }

    private static func sensitivityRank(_ value: SensitivityDTO) -> Int {
        if value == .public {
            0
        } else if value == .private {
            1
        } else if value == .secret {
            2
        } else {
            2
        }
    }
}
