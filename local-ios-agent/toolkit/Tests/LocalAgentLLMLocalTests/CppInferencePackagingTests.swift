import Foundation
import Testing
@testable import LocalAgentLLMLocal

@Suite("C++ inference packaging")
struct CppInferencePackagingTests {
    @Test
    func shippedNativeRegistryIsNonEmptyAndReleaseOnly() throws {
        let engines = try CppInferenceRegistry.live.listEngines()
        let releaseManifest = try JSONDecoder().decode(
            ReleaseEngineManifest.self,
            from: Data(contentsOf: releaseEngineManifestURL())
        )

        #expect(!engines.isEmpty)
        #expect(Set(engines.map(\.engineID)) == Set(releaseManifest.engineIDs))
        #expect(engines.allSatisfy { !$0.testOnly && $0.engineID != "mock" })

        let capabilities = try CppInferenceRegistry.live.capabilities(engineID: "llama_cpp")
        #expect(capabilities.supportedModelFormats.contains("gguf"))
        #expect(capabilities.supportsStreaming)
        #expect(capabilities.supportsCancellation)
    }
}

private struct ReleaseEngineManifest: Decodable {
    let engineIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case engineIDs = "engine_ids"
    }
}

private func releaseEngineManifestURL(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("inference/release-engines.json")
}
