import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import LocalNativeToolkit

struct OpenMinisToolDefinitionSnapshot: Equatable, Sendable {
    let name: String
    let displayTitle: String
    let description: String
    let inputSchema: CanonicalJSONValue
    let requiredFields: [String]
    let mode: NativeToolMode
    let riskLevel: RiskLevelDTO
    let approvalPolicy: NativeToolApprovalPolicy
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
                displayTitle: "Run Linux Command",
                description: "Execute a command in an isolated Alpine Linux process. Each invocation is a fresh process with stdout and stderr captured. The bundled localagent-mcp-cli manages and invokes MCP servers from the guest.",
                properties: [
                    ("tool_title", "string"),
                    ("command", "string"),
                    ("timeout", "integer"),
                    ("delay", "integer"),
                ],
                required: ["tool_title", "command"],
                riskLevel: .confirm
            ),
            definition(
                name: "file_read",
                displayTitle: "Read File",
                description: "Read a text file from the Linux filesystem or a LocalAgent virtual mount.",
                properties: [
                    ("tool_title", "string"),
                    ("path", "string"),
                    ("offset", "integer"),
                    ("lines", "integer"),
                    ("max_length", "integer"),
                    ("direction", "string"),
                ],
                required: ["tool_title", "path"],
                enums: ["direction": ["head", "tail"]]
            ),
            definition(
                name: "file_write",
                displayTitle: "Write File",
                description: "Write text to the Linux filesystem or a writable LocalAgent virtual mount.",
                properties: [
                    ("tool_title", "string"),
                    ("path", "string"),
                    ("content", "string"),
                    ("append", "boolean"),
                    ("create_dirs", "boolean"),
                ],
                required: ["tool_title", "path", "content"],
                riskLevel: .destructive
            ),
            definition(
                name: "file_edit",
                displayTitle: "Edit File",
                description: "Make an exact string replacement in an existing file.",
                properties: [
                    ("tool_title", "string"),
                    ("path", "string"),
                    ("old_string", "string"),
                    ("new_string", "string"),
                    ("replace_all", "boolean"),
                ],
                required: ["tool_title", "path", "old_string", "new_string"],
                riskLevel: .destructive
            ),
            definition(
                name: "browser_use",
                displayTitle: "Use Browser",
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
                required: ["tool_title", "action"],
                enums: [
                    "action": BrowserAction.allCases.map(\.rawValue),
                    "direction": ["up", "down"],
                    "user_agent": ["desktop_safari", "mobile_safari"],
                ],
                riskLevel: .confirm
            ),
            definition(
                name: "read_image",
                displayTitle: "Read Image (Multimodal)",
                description: "Read an image from the Linux filesystem or a LocalAgent virtual mount and attach bounded RGB pixels to the next model turn for visual analysis.",
                properties: [
                    ("tool_title", "string"),
                    ("path", "string"),
                ],
                required: ["tool_title", "path"]
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
                displayTitle: schema.name,
                description: schema.description,
                inputSchema: inputSchema,
                requiredFields: Self.requiredFields(from: inputSchema),
                mode: .background,
                riskLevel: schema.riskLevel,
                approvalPolicy: .never
            )
        }
        return try Self(orderedDefinitions: builtIns + native)
    }

    private static func definition(
        name: String,
        displayTitle: String,
        description: String,
        properties: [(String, String)],
        required: [String],
        enums: [String: [String]] = [:],
        riskLevel: RiskLevelDTO = .readOnly
    ) throws -> OpenMinisToolDefinitionSnapshot {
        let propertyEntries = try properties.map { name, type in
            var entries = [
                CanonicalJSONObjectEntry(name: "type", value: .string(type)),
            ]
            if let values = enums[name] {
                entries.append(CanonicalJSONObjectEntry(
                    name: "enum",
                    value: .array(values.map(CanonicalJSONValue.string))
                ))
            }
            return CanonicalJSONObjectEntry(
                name: name,
                value: try .object(entries: entries)
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
            displayTitle: displayTitle,
            description: description,
            inputSchema: schema,
            requiredFields: required,
            mode: .background,
            riskLevel: riskLevel,
            approvalPolicy: .never
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
