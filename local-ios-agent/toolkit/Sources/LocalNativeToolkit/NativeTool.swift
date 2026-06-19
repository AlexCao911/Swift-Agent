import Foundation
import LocalAgentBridge

public enum NativeToolRiskLevel: Sendable, Equatable {
    case readOnly
    case confirm
    case destructive
}

public struct JSONSchemaDTO: Sendable, Equatable {
    public var jsonString: String

    public init(jsonString: String) {
        self.jsonString = jsonString
    }

    public static func object(
        properties: [String: JSONSchemaDTO] = [:],
        required: [String] = []
    ) -> JSONSchemaDTO {
        guard !properties.isEmpty || !required.isEmpty else {
            return JSONSchemaDTO(jsonString: #"{"type":"object"}"#)
        }

        var parts = [#""type":"object""#]
        if !properties.isEmpty {
            let renderedProperties = properties
                .sorted { $0.key < $1.key }
                .map { key, schema in
                    "\(jsonStringLiteral(key)):\(schema.jsonString)"
                }
                .joined(separator: ",")
            parts.append(#""properties":{\#(renderedProperties)}"#)
        }
        if !required.isEmpty {
            let renderedRequired = required
                .sorted()
                .map(jsonStringLiteral)
                .joined(separator: ",")
            parts.append(#""required":[\#(renderedRequired)]"#)
        }

        return JSONSchemaDTO(jsonString: "{\(parts.joined(separator: ","))}")
    }

    public static func string() -> JSONSchemaDTO {
        JSONSchemaDTO(jsonString: #"{"type":"string"}"#)
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

public enum NativePermissionState: Sendable, Equatable {
    case unknown
    case granted
    case denied
    case restricted
}

public struct NativePermissionScope: Sendable, Hashable, ExpressibleByStringLiteral {
    public var name: String

    public init(_ name: String) {
        self.name = name
    }

    public init(stringLiteral value: String) {
        self.name = value
    }
}

public enum NativeToolAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

public struct NativeToolSchema: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONSchemaDTO
    public var riskLevel: NativeToolRiskLevel
    public var permissionScope: NativePermissionScope?
    public var availability: NativeToolAvailability

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchemaDTO,
        riskLevel: NativeToolRiskLevel,
        permissionScope: NativePermissionScope?,
        availability: NativeToolAvailability
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.riskLevel = riskLevel
        self.permissionScope = permissionScope
        self.availability = availability
    }
}

public protocol NativeTool: Sendable {
    var schema: NativeToolSchema { get }

    func execute(argumentsJson: String) async -> ToolResultDTO
}
