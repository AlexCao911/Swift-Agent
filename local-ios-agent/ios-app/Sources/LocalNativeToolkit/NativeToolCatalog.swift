public enum NativeToolCatalogError: Error, Equatable {
    case duplicateToolName(String)
}

public struct NativeToolCatalog: Sendable {
    public let tools: [any NativeTool]

    public init(tools: [any NativeTool]) throws {
        var seenNames: Set<String> = []
        for tool in tools {
            let name = tool.schema.name
            guard seenNames.insert(name).inserted else {
                throw NativeToolCatalogError.duplicateToolName(name)
            }
        }
        self.tools = tools
    }

    public var schemas: [NativeToolSchema] {
        tools.map(\.schema).sorted { $0.name < $1.name }
    }
}
