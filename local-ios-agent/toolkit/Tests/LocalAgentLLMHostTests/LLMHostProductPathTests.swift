import Foundation
import Testing

@Suite("LLM host product path")
struct LLMHostProductPathTests {
    @Test
    func productRuntimeHasNoLegacyRouteRouter() throws {
        let toolkit = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: toolkit.appendingPathComponent(
                "Sources/LocalAgentLLMHost/LLMHostProductRuntime.swift"
            ),
            encoding: .utf8
        )

        #expect(!source.contains("LLMProductRunRouter"))
        #expect(!source.contains("ProfileExecutionRouteClient"))
    }
}
