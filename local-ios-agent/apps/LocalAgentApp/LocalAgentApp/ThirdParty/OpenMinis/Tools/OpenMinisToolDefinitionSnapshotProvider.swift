import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts

struct OpenMinisToolDefinitionSnapshot: Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: CanonicalJSONValue
    let requiredFields: [String]
}

struct OpenMinisToolDefinitionSnapshotProvider: Sendable {
    let orderedDefinitions: [OpenMinisToolDefinitionSnapshot]

    init(orderedDefinitions: [OpenMinisToolDefinitionSnapshot]) throws {
        var names = Set<String>()
        for definition in orderedDefinitions {
            guard names.insert(definition.name).inserted else {
                throw DefinitionError(code: "tool_schema.duplicate_name")
            }
            guard definition.inputSchema.objectValue(forKey: "type") == .string("object") else {
                throw DefinitionError(code: "tool_schema.root_not_object")
            }
        }
        self.orderedDefinitions = orderedDefinitions
    }

    func definition(named name: String) -> OpenMinisToolDefinitionSnapshot? {
        orderedDefinitions.first { $0.name == name }
    }

    static func productDefaults(
        nativeSchemas: [ToolSchemaDTO] = []
    ) throws -> Self {
        let builtIns = try [
            definition(
                name: "shell_execute",
                description: "Execute a command in an isolated Alpine Linux process. Each invocation is a fresh process with stdout and stderr captured. The bundled localagent-mcp-cli manages and invokes MCP servers from the guest.",
                properties: [
                    ("tool_title", "string"),
                    ("command", "string"),
                    ("timeout", "integer"),
                    ("delay", "integer"),
                ],
                required: ["tool_title", "command"]
            ),
            definition(
                name: "file_read",
                description: "Read a text file from the Linux filesystem or a LocalAgent virtual mount.",
                properties: [
                    ("tool_title", "string"),
                    ("path", "string"),
                    ("offset", "integer"),
                    ("lines", "integer"),
                    ("max_length", "integer"),
                    ("direction", "string"),
                ],
                required: ["tool_title", "path"]
            ),
            definition(
                name: "file_write",
                description: "Write text to the Linux filesystem or a writable LocalAgent virtual mount.",
                properties: [
                    ("tool_title", "string"),
                    ("path", "string"),
                    ("content", "string"),
                    ("append", "boolean"),
                    ("create_dirs", "boolean"),
                ],
                required: ["tool_title", "path", "content"]
            ),
            definition(
                name: "file_edit",
                description: "Make an exact string replacement in an existing file.",
                properties: [
                    ("tool_title", "string"),
                    ("path", "string"),
                    ("old_string", "string"),
                    ("new_string", "string"),
                    ("replace_all", "boolean"),
                ],
                required: ["tool_title", "path", "old_string", "new_string"]
            ),
            definition(
                name: "browser_use",
                description: "Control the product browser with up to three tabs. Navigate web and localagent:// resource URLs; inspect, interact with, capture, and download page content; manage tabs, cookies, user agent, and viewport.",
                properties: [
                    ("tool_title", "string"),
                    ("action", "string"),
                    ("url", "string"),
                    ("selector", "string"),
                    ("text", "string"),
                    ("coordinate_x", "integer"),
                    ("coordinate_y", "integer"),
                    ("direction", "string"),
                    ("amount", "integer"),
                    ("script", "string"),
                    ("user_agent", "string"),
                    ("max_depth", "integer"),
                    ("tab_id", "integer"),
                    ("scroll_count", "integer"),
                    ("item_selector", "string"),
                    ("keywords", "string"),
                    ("fuzzy", "boolean"),
                    ("cookies", "string"),
                    ("timeout", "integer"),
                    ("viewport_width", "integer"),
                    ("viewport_height", "integer"),
                    ("reset", "boolean"),
                    ("full_page", "boolean"),
                ],
                required: ["tool_title", "action"]
            ),
        ]
        let native = try nativeSchemas.map { schema in
            guard let data = schema.parametersJsonSchema.data(using: .utf8) else {
                throw DefinitionError(code: "tool_schema.invalid_utf8")
            }
            let inputSchema: CanonicalJSONValue
            do {
                inputSchema = try JSONDecoder().decode(
                    CanonicalJSONValue.self,
                    from: data
                )
            } catch {
                throw DefinitionError(code: "tool_schema.invalid_json")
            }
            guard inputSchema.objectValue(forKey: "type") == .string("object") else {
                throw DefinitionError(code: "tool_schema.root_not_object")
            }
            return OpenMinisToolDefinitionSnapshot(
                name: schema.name,
                description: schema.description,
                inputSchema: inputSchema,
                requiredFields: Self.requiredFields(from: inputSchema)
            )
        }
        return try Self(orderedDefinitions: builtIns + native)
    }

    private static func definition(
        name: String,
        description: String,
        properties: [(String, String)],
        required: [String]
    ) throws -> OpenMinisToolDefinitionSnapshot {
        let propertyEntries = try properties.map { name, type in
            CanonicalJSONObjectEntry(
                name: name,
                value: try .object(entries: [
                    CanonicalJSONObjectEntry(name: "type", value: .string(type)),
                ])
            )
        }
        let schema = try CanonicalJSONValue.object(entries: [
            CanonicalJSONObjectEntry(name: "type", value: .string("object")),
            CanonicalJSONObjectEntry(
                name: "properties",
                value: try .object(entries: propertyEntries)
            ),
            CanonicalJSONObjectEntry(
                name: "required",
                value: .array(required.map(CanonicalJSONValue.string))
            ),
            CanonicalJSONObjectEntry(name: "additionalProperties", value: .bool(false)),
        ])
        return OpenMinisToolDefinitionSnapshot(
            name: name,
            description: description,
            inputSchema: schema,
            requiredFields: required
        )
    }

    private static func requiredFields(
        from schema: CanonicalJSONValue
    ) -> [String] {
        guard case .array(let values) = schema.objectValue(forKey: "required") else {
            return []
        }
        return values.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
    }

    struct DefinitionError: Error, Equatable, Sendable {
        let code: String
    }
}
