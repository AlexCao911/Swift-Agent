import Foundation
import LocalAgentInferenceNative

package protocol CppInferenceRegistryAPI: Sendable {
    func listEngines() throws -> [CppEngineDescriptor]
    func capabilities(engineID: String) throws -> CppEngineCapabilities
}

package struct CppEngineDescriptor: Decodable, Equatable, Sendable {
    package let engineID: String
    package let displayName: String
    package let testOnly: Bool
    package let capabilities: CppEngineCapabilities

    private enum CodingKeys: String, CodingKey {
        case engineID = "engine_id"
        case displayName = "display_name"
        case testOnly = "test_only"
        case capabilities
    }
}

package struct CppEngineCapabilities: Decodable, Equatable, Sendable {
    package let supportedModelFormats: Set<String>
    package let supportsVision: Bool
    package let supportsStreaming: Bool
    package let supportsCancellation: Bool
    package let supportsTokenUsage: Bool
    package let maxContextTokens: UInt64?

    private enum CodingKeys: String, CodingKey {
        case supportedModelFormats = "supported_model_formats"
        case supportsVision = "supports_vision"
        case supportsStreaming = "supports_streaming"
        case supportsCancellation = "supports_cancellation"
        case supportsTokenUsage = "supports_token_usage"
        case maxContextTokens = "max_context_tokens"
    }
}

package enum CppInferenceRegistry {
    package static let live: any CppInferenceRegistryAPI = LiveCppInferenceRegistry()
}

package enum CppInferenceRegistryError: Error, Equatable, Sendable {
    case nativeStatus(Int32)
    case missingOutput
    case unknownEngine(String)
}

private struct LiveCppInferenceRegistry: CppInferenceRegistryAPI {
    func listEngines() throws -> [CppEngineDescriptor] {
        var output: UnsafeMutablePointer<CChar>?
        let status = local_agent_engine_list(&output)
        guard status == LOCAL_AGENT_STATUS_OK else {
            throw CppInferenceRegistryError.nativeStatus(Int32(status.rawValue))
        }
        guard let output else {
            throw CppInferenceRegistryError.missingOutput
        }
        defer { local_agent_string_free(output) }
        return try JSONDecoder().decode(
            [CppEngineDescriptor].self,
            from: Data(String(cString: output).utf8)
        )
    }

    func capabilities(engineID: String) throws -> CppEngineCapabilities {
        guard try listEngines().contains(where: { $0.engineID == engineID }) else {
            throw CppInferenceRegistryError.unknownEngine(engineID)
        }

        var engine: OpaquePointer?
        let createStatus = engineID.withCString {
            local_agent_engine_create($0, &engine)
        }
        guard createStatus == LOCAL_AGENT_STATUS_OK else {
            throw CppInferenceRegistryError.nativeStatus(Int32(createStatus.rawValue))
        }
        guard let engine else {
            throw CppInferenceRegistryError.missingOutput
        }
        defer { _ = local_agent_engine_release(engine) }

        var output: UnsafeMutablePointer<CChar>?
        let capabilitiesStatus = local_agent_engine_capabilities(engine, &output)
        guard capabilitiesStatus == LOCAL_AGENT_STATUS_OK else {
            throw CppInferenceRegistryError.nativeStatus(Int32(capabilitiesStatus.rawValue))
        }
        guard let output else {
            throw CppInferenceRegistryError.missingOutput
        }
        defer { local_agent_string_free(output) }
        return try JSONDecoder().decode(
            CppEngineCapabilities.self,
            from: Data(String(cString: output).utf8)
        )
    }
}

public enum LocalInferenceNativeRegistry {
    public static func releaseEngineIDs() throws -> [String] {
        try CppInferenceRegistry.live.listEngines().map(\.engineID).sorted()
    }
}

/// A link-time probe used by the App integration target. Keeping every C ABI
/// entry point in one referenced tuple makes the final test host prove that the
/// sole XCFramework slice, including its vendor objects, resolves the complete
/// boundary rather than only the registry function exercised by Task 1.
public enum LocalInferenceNativeLinkProbe {
    @inline(never)
    public static func requireAllExports() {
        precondition(
            local_agent_link_anchor() == 12,
            "Local inference C ABI final-link anchor is incomplete"
        )
    }
}
