import Foundation
import LocalAgentLLMContracts

public struct PromptDocumentSnapshotDTO: Codable, Equatable, Sendable {
    public let id: String
    public let source: String
    public let markdown: String

    public init(id: String, source: String, markdown: String) {
        self.id = id
        self.source = source
        self.markdown = markdown
    }
}

public struct RustSkillDescriptorDTO: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let location: String
    public let enabled: Bool

    public init(
        id: String,
        name: String,
        description: String,
        location: String,
        enabled: Bool
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.location = location
        self.enabled = enabled
    }
}

public struct ToolDefinitionSnapshotDTO: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: CanonicalJSONValue

    public init(
        name: String,
        description: String,
        inputSchema: CanonicalJSONValue
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }
}

public struct RunStartSnapshotDTO: Codable, Equatable, Sendable {
    public static let maximumSkillDescriptors = 20

    public let orderedPromptDocuments: [PromptDocumentSnapshotDTO]
    public let skillDescriptors: [RustSkillDescriptorDTO]
    public let orderedToolDefinitions: [ToolDefinitionSnapshotDTO]
    public let snapshotDigest: String

    public init(
        orderedPromptDocuments: [PromptDocumentSnapshotDTO],
        skillDescriptors: [RustSkillDescriptorDTO],
        orderedToolDefinitions: [ToolDefinitionSnapshotDTO],
        snapshotDigest: String
    ) {
        self.orderedPromptDocuments = orderedPromptDocuments
        self.skillDescriptors = skillDescriptors
        self.orderedToolDefinitions = orderedToolDefinitions
        self.snapshotDigest = snapshotDigest
    }

    public static func make(
        orderedPromptDocuments: [PromptDocumentSnapshotDTO],
        skillDescriptors: [RustSkillDescriptorDTO],
        orderedToolDefinitions: [ToolDefinitionSnapshotDTO]
    ) throws -> Self {
        let unsigned = Self(
            orderedPromptDocuments: orderedPromptDocuments,
            skillDescriptors: skillDescriptors,
            orderedToolDefinitions: orderedToolDefinitions,
            snapshotDigest: ""
        )
        try unsigned.validateFields()
        return Self(
            orderedPromptDocuments: orderedPromptDocuments,
            skillDescriptors: skillDescriptors,
            orderedToolDefinitions: orderedToolDefinitions,
            snapshotDigest: try unsigned.recomputedDigest()
        )
    }

    public func validate() throws {
        try validateFields()
        guard snapshotDigest.count == 64,
              snapshotDigest.utf8.allSatisfy({
                  ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
              }),
              snapshotDigest == (try recomputedDigest()) else {
            throw RunStartSnapshotValidationError(
                code: "run_start_snapshot.digest_mismatch"
            )
        }
    }

    public func recomputedDigest() throws -> String {
        let document = SnapshotDigestDocument(
            orderedPromptDocuments: orderedPromptDocuments,
            skillDescriptors: skillDescriptors,
            orderedToolDefinitions: orderedToolDefinitions
        )
        let data = try JSONEncoder().encode(document)
        let canonical = try JSONDecoder().decode(
            CanonicalJSONValue.self,
            from: data
        )
        return try CanonicalDigestV1.digest(
            domain: "run-start-snapshot:v1",
            document: canonical
        ).hex
    }

    private func validateFields() throws {
        guard skillDescriptors.count <= Self.maximumSkillDescriptors else {
            throw RunStartSnapshotValidationError(
                code: "run_start_snapshot.too_many_skills"
            )
        }
        try requireUnique(
            orderedPromptDocuments.map(\.id),
            code: "run_start_snapshot.duplicate_prompt_document_id"
        )
        try requireUnique(
            skillDescriptors.map(\.id),
            code: "run_start_snapshot.duplicate_skill_id"
        )
        try requireUnique(
            orderedToolDefinitions.map(\.name),
            code: "run_start_snapshot.duplicate_tool_name"
        )

        for document in orderedPromptDocuments {
            guard !document.id.isEmpty,
                  !document.source.isEmpty,
                  !document.source.hasPrefix("/") else {
                throw RunStartSnapshotValidationError(
                    code: "run_start_snapshot.prompt_document_invalid"
                )
            }
        }
        for descriptor in skillDescriptors {
            guard descriptor.enabled,
                  !descriptor.id.isEmpty,
                  !descriptor.name.isEmpty,
                  isValidSkillLocation(
                      descriptor.location,
                      id: descriptor.id
                  ) else {
                throw RunStartSnapshotValidationError(
                    code: "run_start_snapshot.skill_location_invalid"
                )
            }
        }
        for tool in orderedToolDefinitions {
            guard !tool.name.isEmpty,
                  tool.inputSchema.objectValue(forKey: "type")
                    == .string("object") else {
                throw RunStartSnapshotValidationError(
                    code: "run_start_snapshot.tool_schema_not_object"
                )
            }
        }
    }

    private func isValidSkillLocation(_ location: String, id: String) -> Bool {
        let prefix = "/var/localagent/skills/"
        let suffix = "/SKILL.md"
        guard location.hasPrefix(prefix),
              location.hasSuffix(suffix) else {
            return false
        }
        let start = location.index(location.startIndex, offsetBy: prefix.count)
        let end = location.index(location.endIndex, offsetBy: -suffix.count)
        let component = String(location[start..<end])
        guard component == id,
              component != ".",
              component != "..",
              !component.isEmpty else {
            return false
        }
        return component.utf8.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5A)
                || ($0 >= 0x61 && $0 <= 0x7A)
                || ($0 >= 0x30 && $0 <= 0x39)
                || $0 == 0x2D
                || $0 == 0x2E
                || $0 == 0x5F
        }
    }

    private func requireUnique(
        _ values: [String],
        code: String
    ) throws {
        guard Set(values).count == values.count else {
            throw RunStartSnapshotValidationError(code: code)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case orderedPromptDocuments = "ordered_prompt_documents"
        case skillDescriptors = "skill_descriptors"
        case orderedToolDefinitions = "ordered_tool_definitions"
        case snapshotDigest = "snapshot_digest"
    }
}

public struct RunStartSnapshotValidationError: Error, Equatable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

private struct SnapshotDigestDocument: Codable {
    let orderedPromptDocuments: [PromptDocumentSnapshotDTO]
    let skillDescriptors: [RustSkillDescriptorDTO]
    let orderedToolDefinitions: [ToolDefinitionSnapshotDTO]

    private enum CodingKeys: String, CodingKey {
        case orderedPromptDocuments = "ordered_prompt_documents"
        case skillDescriptors = "skill_descriptors"
        case orderedToolDefinitions = "ordered_tool_definitions"
    }
}
