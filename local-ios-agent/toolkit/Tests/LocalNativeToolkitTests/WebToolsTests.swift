import Foundation
import LocalAgentBridge
import Testing
@testable import LocalNativeToolkit

@Suite("Web native tools")
struct WebToolsTests {
    @Test
    func fetchURLTextPreservesPolicyDeniedCode() async throws {
        let tool = WebFetchURLTextTool(fetcher: PolicyDeniedWebFetcher(
            code: "web_fetch.private_network_denied"
        ))

        let result = await tool.execute(argumentsJson: #"{"url":"https://example.com"}"#)
        let code = try resultCode(from: result)

        #expect(result.isError)
        #expect(code == "web_fetch.private_network_denied")
        #expect(result.auditText.contains("web_fetch.private_network_denied"))
    }

    private func resultCode(from result: ToolResultDTO) throws -> String {
        let data = try #require(result.structuredJson.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["result"] as? [String: Any])
        return try #require(payload["code"] as? String)
    }
}

private struct PolicyDeniedWebFetcher: WebFetching {
    let code: String

    func fetch(_ request: URLRequest, policy: WebFetchPolicyV1) async throws -> WebFetchResponse {
        throw WebFetchError.policyDenied(code)
    }
}
