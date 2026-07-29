import Foundation

public struct OAuthHTTPFailure: Error, Equatable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

public struct OAuthEndpointProfile: Equatable, Sendable {
    public let id: String
    public let baseURL: URL
    public let expectedOrigin: EgressOrigin
    public let allowedPaths: Set<String>

    public init(
        id: String,
        baseURL: URL,
        expectedOrigin: EgressOrigin,
        allowedPaths: Set<String>
    ) throws {
        guard !id.isEmpty,
              let components = URLComponents(
                  url: baseURL,
                  resolvingAgainstBaseURL: false
              ),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == expectedOrigin.host,
              expectedOrigin.scheme == "https",
              (components.port ?? 443) == Int(expectedOrigin.port),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              !allowedPaths.isEmpty,
              allowedPaths.allSatisfy(Self.validPath)
        else {
            throw OAuthHTTPFailure(code: "oauth.endpoint_profile_invalid")
        }
        self.id = id
        self.baseURL = baseURL
        self.expectedOrigin = expectedOrigin
        self.allowedPaths = allowedPaths
    }

    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && !path.hasPrefix("//")
            && !path.contains("?")
            && !path.contains("#")
            && path.split(separator: "/").allSatisfy {
                let value = String($0).removingPercentEncoding ?? String($0)
                return value != "." && value != ".." && !value.contains("\0")
            }
    }
}

public struct OAuthHTTPRequest: Equatable, Sendable {
    public let profile: OAuthEndpointProfile
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data?

    public init(
        profile: OAuthEndpointProfile,
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) throws {
        let forbiddenHeaders = Set([
            "authorization",
            "proxy-authorization",
            "cookie",
            "set-cookie",
            "x-api-key",
            "x-goog-api-key",
        ])
        guard method == "GET" || method == "POST",
              profile.allowedPaths.contains(path),
              (method == "POST" || body == nil),
              headers.allSatisfy({
                  let name = $0.key.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).lowercased()
                  return !name.isEmpty
                      && !forbiddenHeaders.contains(name)
                      && !$0.key.contains("\r")
                      && !$0.key.contains("\n")
                      && !$0.value.contains("\r")
                      && !$0.value.contains("\n")
              })
        else {
            throw OAuthHTTPFailure(code: "oauth.request_invalid")
        }
        self.profile = profile
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct OAuthHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct OAuthHTTPClient: Sendable {
    private let sendRequest:
        @Sendable (OAuthHTTPRequest) async throws -> OAuthHTTPResponse

    package init(transport: any CloudHTTPTransport) {
        sendRequest = { try await transport.oauth($0) }
    }

    public init(
        send: @escaping
            @Sendable (OAuthHTTPRequest) async throws -> OAuthHTTPResponse
    ) {
        sendRequest = send
    }

    public func send(
        _ request: OAuthHTTPRequest
    ) async throws -> OAuthHTTPResponse {
        try Task.checkCancellation()
        do {
            let response = try await sendRequest(request)
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw CancellationError()
        }
    }
}
