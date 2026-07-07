import Foundation
import Testing
@testable import LocalNativeToolkit

@Suite("Web fetch policy")
struct WebFetchPolicyTests {
    @Test
    func allowsHttpsTextRequestWithoutCredentials() throws {
        var request = URLRequest(url: try #require(URL(string: "https://example.com/article")))
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let decision = WebFetchPolicyV1.default.validate(request)

        #expect(decision == .allowed)
    }

    @Test
    func rejectsUnsafeSchemesAndCredentials() throws {
        let fileDecision = WebFetchPolicyV1.default.validate(URLRequest(url: URL(fileURLWithPath: "/etc/passwd")))
        #expect(fileDecision == .denied(code: "web_fetch.scheme_denied"))

        var request = URLRequest(url: try #require(URL(string: "https://example.com/private")))
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        #expect(WebFetchPolicyV1.default.validate(request) == .denied(code: "web_fetch.credentials_denied"))
    }

    @Test
    func rejectsLocalAndPrivateHosts() throws {
        let localhost = URLRequest(url: try #require(URL(string: "https://localhost:8080")))
        let privateLan = URLRequest(url: try #require(URL(string: "https://192.168.1.10/status")))

        #expect(WebFetchPolicyV1.default.validate(localhost) == .denied(code: "web_fetch.private_network_denied"))
        #expect(WebFetchPolicyV1.default.validate(privateLan) == .denied(code: "web_fetch.private_network_denied"))
    }

    @Test
    func rejectsIPv6LocalHosts() throws {
        let loopback = URLRequest(url: try #require(URL(string: "https://[::1]/admin")))
        let uniqueLocal = URLRequest(url: try #require(URL(string: "https://[fd00::1]/status")))
        let linkLocal = URLRequest(url: try #require(URL(string: "https://[fe80::1]/status")))

        #expect(WebFetchPolicyV1.default.validate(loopback) == .denied(code: "web_fetch.private_network_denied"))
        #expect(WebFetchPolicyV1.default.validate(uniqueLocal) == .denied(code: "web_fetch.private_network_denied"))
        #expect(WebFetchPolicyV1.default.validate(linkLocal) == .denied(code: "web_fetch.private_network_denied"))
    }

    @Test
    func rejectsRedirectToPrivateNetworkBeforeFollow() throws {
        let source = URLRequest(url: try #require(URL(string: "https://example.com/article")))
        let redirected = URLRequest(url: try #require(URL(string: "https://localhost:8080/private")))

        let decision = WebFetchPolicyV1.default.validateRedirect(
            from: source,
            to: redirected,
            redirectCount: 1
        )

        #expect(decision == .denied(code: "web_fetch.private_network_denied"))
    }

    @Test
    func rejectsRedirectCountOverLimit() throws {
        let source = URLRequest(url: try #require(URL(string: "https://example.com/article")))
        let redirected = URLRequest(url: try #require(URL(string: "https://example.org/next")))
        let policy = WebFetchPolicyV1(
            maxResponseBytes: 512_000,
            maxExtractedTextCharacters: 100_000,
            timeoutSeconds: 20,
            maxRedirects: 1
        )

        let decision = policy.validateRedirect(
            from: source,
            to: redirected,
            redirectCount: 2
        )

        #expect(decision == .denied(code: "web_fetch.redirect_limit_exceeded"))
    }
}
