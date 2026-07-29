import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentBridge

@Suite("Run-start snapshot DTO")
struct RunStartSnapshotDTOTests {
    @Test
    func computesAndVerifiesCanonicalDigestWithSnakeCaseWireKeys() throws {
        let snapshot = try makeSnapshot()

        try snapshot.validate()
        #expect(
            snapshot.snapshotDigest
                == "770d63806ac4bd25a4886d9f7383989bbb2bfe3ad6eb35ca85fc239850581f18"
        )

        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["ordered_prompt_documents"] != nil)
        #expect(object["skill_descriptors"] != nil)
        #expect(object["ordered_tool_definitions"] != nil)
        #expect(object["snapshot_digest"] != nil)
    }

    @Test
    func changedFieldCannotReuseTheOriginalDigest() throws {
        let original = try makeSnapshot()
        let changed = RunStartSnapshotDTO(
            orderedPromptDocuments: [
                PromptDocumentSnapshotDTO(
                    id: "base",
                    source: "settings",
                    markdown: "Changed"
                ),
            ],
            skillDescriptors: original.skillDescriptors,
            orderedToolDefinitions: original.orderedToolDefinitions,
            snapshotDigest: original.snapshotDigest
        )

        expectCode("run_start_snapshot.digest_mismatch") {
            try changed.validate()
        }
    }

    @Test
    func rejectsMoreThanTwentySkillDescriptors() throws {
        let descriptors = (0..<21).map { index in
            RustSkillDescriptorDTO(
                id: "skill-\(index)",
                name: "Skill \(index)",
                description: "Description",
                location: "/var/localagent/skills/skill-\(index)/SKILL.md",
                enabled: true
            )
        }

        expectCode("run_start_snapshot.too_many_skills") {
            _ = try RunStartSnapshotDTO.make(
                orderedPromptDocuments: [],
                skillDescriptors: descriptors,
                orderedToolDefinitions: []
            )
        }
    }

    @Test
    func rejectsHostPathAndTraversalInSkillLocation() {
        for location in [
            "/private/var/mobile/Containers/Data/Application/host/SKILL.md",
            "/var/localagent/skills/../shared/secret/SKILL.md",
            "/var/localagent/skills/demo/references/extra.md",
        ] {
            expectCode("run_start_snapshot.skill_location_invalid") {
                _ = try RunStartSnapshotDTO.make(
                    orderedPromptDocuments: [],
                    skillDescriptors: [
                        RustSkillDescriptorDTO(
                            id: "demo",
                            name: "Demo",
                            description: "Demo skill",
                            location: location,
                            enabled: true
                        ),
                    ],
                    orderedToolDefinitions: []
                )
            }
        }
    }

    @Test
    func rejectsDuplicateToolsAndNonObjectSchemas() throws {
        let objectSchema = try CanonicalJSONValue.object(entries: [
            .init(name: "type", value: .string("object")),
        ])
        let duplicate = ToolDefinitionSnapshotDTO(
            name: "shell_execute",
            description: "Shell",
            inputSchema: objectSchema
        )

        expectCode("run_start_snapshot.duplicate_tool_name") {
            _ = try RunStartSnapshotDTO.make(
                orderedPromptDocuments: [],
                skillDescriptors: [],
                orderedToolDefinitions: [duplicate, duplicate]
            )
        }
        expectCode("run_start_snapshot.tool_schema_not_object") {
            _ = try RunStartSnapshotDTO.make(
                orderedPromptDocuments: [],
                skillDescriptors: [],
                orderedToolDefinitions: [
                    ToolDefinitionSnapshotDTO(
                        name: "bad",
                        description: "Bad",
                        inputSchema: .array([])
                    ),
                ]
            )
        }
    }

    private func makeSnapshot() throws -> RunStartSnapshotDTO {
        try RunStartSnapshotDTO.make(
            orderedPromptDocuments: [
                PromptDocumentSnapshotDTO(
                    id: "base",
                    source: "settings",
                    markdown: "You are LocalAgent."
                ),
            ],
            skillDescriptors: [
                RustSkillDescriptorDTO(
                    id: "demo",
                    name: "Demo",
                    description: "Use for demonstrations.",
                    location: "/var/localagent/skills/demo/SKILL.md",
                    enabled: true
                ),
            ],
            orderedToolDefinitions: [
                ToolDefinitionSnapshotDTO(
                    name: "shell_execute",
                    description: "Run shell commands.",
                    inputSchema: try .object(entries: [
                        .init(name: "type", value: .string("object")),
                    ])
                ),
            ]
        )
    }

    private func expectCode(
        _ expected: String,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected \(expected)")
        } catch let error as RunStartSnapshotValidationError {
            #expect(error.code == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
