import LocalAgentLLMLocal
import Testing

@Suite("Local inference native link")
struct LocalInferenceNativeLinkTests {
    @Test("App test host resolves the complete release C ABI")
    func appTestHostResolvesCompleteReleaseCABI() throws {
        LocalInferenceNativeLinkProbe.requireAllExports()
        #expect(try LocalInferenceNativeRegistry.releaseEngineIDs() == ["llama_cpp"])
    }
}
