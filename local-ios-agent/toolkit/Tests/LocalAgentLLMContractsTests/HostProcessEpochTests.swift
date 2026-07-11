import Testing
@testable import LocalAgentLLMContracts

@Suite("Host process epoch")
struct HostProcessEpochTests {
    @Test
    func generatesDistinctCanonical256BitValues() throws {
        let first = try HostProcessEpoch.generate()
        let second = try HostProcessEpoch.generate()

        #expect(first != second)
        #expect(first.rawValue.utf8.count == 43)
        #expect(!first.rawValue.contains("="))
        #expect(HostProcessEpoch(rawValue: first.rawValue) == first)
    }

    @Test(arguments: [
        "",
        "short",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA!",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB",
    ])
    func rejectsNonCanonicalValues(_ rawValue: String) {
        #expect(HostProcessEpoch(rawValue: rawValue) == nil)
    }
}
