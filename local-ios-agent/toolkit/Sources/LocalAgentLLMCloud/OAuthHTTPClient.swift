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

public enum ProviderOAuthFlow: String, Equatable, Sendable {
    case deviceCode = "device_code"
    case authorizationCodePKCE = "authorization_code_pkce"
}

public enum OAuthTokenBodyEncoding: String, Equatable, Sendable {
    case formURLEncoded = "form_url_encoded"
    case json
}

public struct ProviderOAuthProfile: Equatable, Sendable {
    public let presetID: ProviderPresetID
    public let flow: ProviderOAuthFlow
    public let authorizationURL: URL?
    public let tokenEndpoint: OAuthEndpointProfile
    public let tokenPath: String
    public let deviceAuthorizationPath: String?
    public let clientID: String
    public let clientSecret: String?
    public let redirectURI: URL?
    public let scopes: [String]
    public let authorizationParameters: [String: String]
    public let tokenBodyEncoding: OAuthTokenBodyEncoding
    public let discoveryEndpoint: OAuthEndpointProfile?
    public let trustedDiscoveryHostSuffixes: Set<String>

    public func authorizationRequestURL(
        state: String,
        codeChallenge: String,
        nonce: String? = nil,
        authorizationURL override: URL? = nil
    ) throws -> URL {
        guard flow == .authorizationCodePKCE,
              let authorizationURL = override ?? authorizationURL,
              let redirectURI,
              !state.isEmpty,
              !codeChallenge.isEmpty,
              var components = URLComponents(
                  url: authorizationURL,
                  resolvingAgainstBaseURL: false
              )
        else {
            throw OAuthHTTPFailure(code: "oauth.authorization_unavailable")
        }
        var parameters = authorizationParameters
        parameters["client_id"] = clientID
        parameters["redirect_uri"] = redirectURI.absoluteString
        parameters["response_type"] = "code"
        parameters["scope"] = scopes.joined(separator: " ")
        parameters["state"] = state
        parameters["code_challenge"] = codeChallenge
        parameters["code_challenge_method"] = "S256"
        if let nonce {
            guard !nonce.isEmpty else {
                throw OAuthHTTPFailure(code: "oauth.nonce_invalid")
            }
            parameters["nonce"] = nonce
        }
        components.queryItems = parameters.keys.sorted().map {
            URLQueryItem(name: $0, value: parameters[$0])
        }
        guard let url = components.url else {
            throw OAuthHTTPFailure(code: "oauth.authorization_url_invalid")
        }
        return url
    }

    public static let shipped: [Self] = {
        let openAI = authorizationCode(
            presetID: .openAI,
            authorizationURL: "https://auth.openai.com/oauth/authorize",
            tokenBaseURL: "https://auth.openai.com",
            tokenPath: "/oauth/token",
            clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
            redirectURI: "http://localhost:1455/auth/callback",
            scopes: ["openid", "profile", "email", "offline_access"],
            authorizationParameters: [
                "codex_cli_simplified_flow": "true",
                "id_token_add_organizations": "true",
                "originator": "codex_cli_rs",
            ],
            tokenBodyEncoding: .json
        )
        return [
            openAI,
            authorizationCode(
                presetID: .anthropic,
                authorizationURL: "https://claude.ai/oauth/authorize",
                tokenBaseURL: "https://console.anthropic.com",
                tokenPath: "/v1/oauth/token",
                clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                redirectURI: "http://localhost:54545/callback",
                scopes: [
                    "org:create_api_key",
                    "user:profile",
                    "user:inference",
                    "user:sessions:claude_code",
                    "user:mcp_servers",
                    "user:file_upload",
                ],
                tokenBodyEncoding: .json
            ),
            authorizationCode(
                presetID: .gemini,
                authorizationURL:
                    "https://accounts.google.com/o/oauth2/v2/auth",
                tokenBaseURL: "https://oauth2.googleapis.com",
                tokenPath: "/token",
                clientID:
                    "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com",
                redirectURI: "http://localhost:8085/oauth2callback",
                scopes: [
                    "https://www.googleapis.com/auth/cloud-platform",
                    "https://www.googleapis.com/auth/userinfo.email",
                    "https://www.googleapis.com/auth/userinfo.profile",
                ],
                authorizationParameters: [
                    "access_type": "offline",
                    "prompt": "consent",
                ]
            ),
            authorizationCode(
                presetID: .xAI,
                authorizationURL: nil,
                tokenBaseURL: "https://auth.x.ai",
                tokenPath: "/oauth/token",
                clientID: "b1a00492-073a-47ea-816f-4c329264a828",
                redirectURI: "http://127.0.0.1:56121/callback",
                scopes: [
                    "openid",
                    "profile",
                    "email",
                    "offline_access",
                    "grok-cli:access",
                    "api:access",
                ],
                authorizationParameters: [
                    "plan": "generic",
                    "referrer": "minis",
                ],
                discoveryPath: "/.well-known/openid-configuration",
                trustedDiscoveryHostSuffixes: ["x.ai"]
            ),
            deviceCode(
                presetID: .kimiCode,
                baseURL: "https://auth.kimi.com",
                devicePath: "/api/oauth/device_authorization",
                tokenPath: "/api/oauth/token",
                clientID: "17e5f671-d194-4dfb-9706-5516cb48c098"
            ),
            authorizationCode(
                presetID: .antigravity,
                authorizationURL:
                    "https://accounts.google.com/o/oauth2/v2/auth",
                tokenBaseURL: "https://oauth2.googleapis.com",
                tokenPath: "/token",
                clientID:
                    "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
                redirectURI: "http://localhost:8086/oauth2callback",
                scopes: [
                    "https://www.googleapis.com/auth/cloud-platform",
                    "https://www.googleapis.com/auth/userinfo.email",
                    "https://www.googleapis.com/auth/userinfo.profile",
                ],
                authorizationParameters: [
                    "access_type": "offline",
                    "prompt": "consent",
                ]
            ),
        ]
    }()

    private static func authorizationCode(
        presetID: ProviderPresetID,
        authorizationURL: String?,
        tokenBaseURL: String,
        tokenPath: String,
        clientID: String,
        redirectURI: String,
        scopes: [String],
        authorizationParameters: [String: String] = [:],
        tokenBodyEncoding: OAuthTokenBodyEncoding = .formURLEncoded,
        discoveryPath: String? = nil,
        trustedDiscoveryHostSuffixes: Set<String> = []
    ) -> Self {
        let baseURL = URL(string: tokenBaseURL)!
        return Self(
            presetID: presetID,
            flow: .authorizationCodePKCE,
            authorizationURL: authorizationURL.flatMap(URL.init(string:)),
            tokenEndpoint: try! OAuthEndpointProfile(
                id: presetID.rawValue,
                baseURL: baseURL,
                expectedOrigin: origin(for: baseURL),
                allowedPaths: [tokenPath]
            ),
            tokenPath: tokenPath,
            deviceAuthorizationPath: nil,
            clientID: clientID,
            clientSecret: nil,
            redirectURI: URL(string: redirectURI)!,
            scopes: scopes,
            authorizationParameters: authorizationParameters,
            tokenBodyEncoding: tokenBodyEncoding,
            discoveryEndpoint: discoveryPath.map { path in
                try! OAuthEndpointProfile(
                    id: "\(presetID.rawValue).discovery",
                    baseURL: baseURL,
                    expectedOrigin: origin(for: baseURL),
                    allowedPaths: [path]
                )
            },
            trustedDiscoveryHostSuffixes: trustedDiscoveryHostSuffixes
        )
    }

    private static func deviceCode(
        presetID: ProviderPresetID,
        baseURL value: String,
        devicePath: String,
        tokenPath: String,
        clientID: String
    ) -> Self {
        let baseURL = URL(string: value)!
        return Self(
            presetID: presetID,
            flow: .deviceCode,
            authorizationURL: nil,
            tokenEndpoint: try! OAuthEndpointProfile(
                id: presetID.rawValue,
                baseURL: baseURL,
                expectedOrigin: origin(for: baseURL),
                allowedPaths: [devicePath, tokenPath]
            ),
            tokenPath: tokenPath,
            deviceAuthorizationPath: devicePath,
            clientID: clientID,
            clientSecret: nil,
            redirectURI: nil,
            scopes: [],
            authorizationParameters: [:],
            tokenBodyEncoding: .formURLEncoded,
            discoveryEndpoint: nil,
            trustedDiscoveryHostSuffixes: []
        )
    }

    static func origin(for url: URL) -> EgressOrigin {
        EgressOrigin(
            scheme: "https",
            host: url.host!,
            port: UInt16(url.port ?? 443)
        )
    }
}

public struct OAuthAuthorizationPreparation: Equatable, Sendable {
    public let profile: ProviderOAuthProfile
    public let authorizationURL: URL
    public let tokenEndpoint: OAuthEndpointProfile
    public let tokenPath: String
    public let state: String
    public let codeChallenge: String
}

public struct OAuthDeviceAuthorization: Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let verificationURLComplete: URL?
    public let expiresIn: TimeInterval
    public let pollingInterval: TimeInterval

    public var browserURL: URL {
        verificationURLComplete ?? verificationURL
    }
}

public struct OAuthTokenCredential: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let idToken: String?
    public let accountID: String?
    public let planType: String?
    public let tokenEndpointURL: URL?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        idToken: String? = nil,
        accountID: String? = nil,
        planType: String? = nil,
        tokenEndpointURL: URL? = nil
    ) throws {
        guard !accessToken.isEmpty,
              !accessToken.contains("\r"),
              !accessToken.contains("\n"),
              refreshToken?.isEmpty != true,
              refreshToken?.contains("\r") != true,
              refreshToken?.contains("\n") != true
        else {
            throw OAuthHTTPFailure(code: "oauth.token_invalid")
        }
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.idToken = idToken
        self.accountID = accountID
        self.planType = planType
        self.tokenEndpointURL = tokenEndpointURL
    }

    public func executableAccessToken(at now: Date = Date()) throws -> String {
        guard expiresAt.map({ $0 > now }) != false else {
            throw OAuthHTTPFailure(code: "oauth.token_expired")
        }
        return accessToken
    }

    public func secureSecret() throws -> SecretBytes {
        SecretBytes(bytes: try JSONEncoder().encode(self))
    }

    package static func decode(from secret: SecretBytes) throws -> Self {
        var data = secret.dataCopyForVault()
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw OAuthHTTPFailure(code: "oauth.credential_invalid")
        }
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

    public func requestDeviceAuthorization(
        profile: OAuthEndpointProfile,
        path: String,
        clientID: String
    ) async throws -> OAuthDeviceAuthorization {
        guard !clientID.isEmpty else {
            throw OAuthHTTPFailure(code: "oauth.client_id_missing")
        }
        let response = try await send(OAuthHTTPRequest(
            profile: profile,
            method: "POST",
            path: path,
            headers: [
                "content-type": "application/x-www-form-urlencoded",
            ],
            body: formBody(["client_id": clientID])
        ))
        guard (200..<300).contains(response.statusCode),
              let value = try? JSONDecoder().decode(
                  DeviceAuthorizationResponse.self,
                  from: response.body
              ),
              !value.deviceCode.isEmpty,
              !value.userCode.isEmpty,
              let verificationURL = URL(
                  string: value.verificationURI
              ),
              verificationURL.scheme?.lowercased() == "https",
              value.expiresIn > 0,
              (value.interval ?? 5) > 0
        else {
            throw OAuthHTTPFailure(
                code: "oauth.device_authorization_failed"
            )
        }
        let complete = value.verificationURIComplete.flatMap(URL.init(string:))
        guard complete?.scheme?.lowercased() != "http" else {
            throw OAuthHTTPFailure(
                code: "oauth.device_authorization_failed"
            )
        }
        return OAuthDeviceAuthorization(
            deviceCode: value.deviceCode,
            userCode: value.userCode,
            verificationURL: verificationURL,
            verificationURLComplete: complete,
            expiresIn: value.expiresIn,
            pollingInterval: value.interval ?? 5
        )
    }

    public func prepareAuthorization(
        profile: ProviderOAuthProfile,
        state: String,
        codeChallenge: String,
        nonce: String?
    ) async throws -> OAuthAuthorizationPreparation {
        guard profile.flow == .authorizationCodePKCE else {
            throw OAuthHTTPFailure(code: "oauth.authorization_unavailable")
        }
        let authorizationURL: URL
        let tokenEndpoint: OAuthEndpointProfile
        let tokenPath: String
        if let discovery = profile.discoveryEndpoint {
            let path = try requireSinglePath(discovery.allowedPaths)
            let response = try await send(OAuthHTTPRequest(
                profile: discovery,
                method: "GET",
                path: path,
                headers: [:],
                body: nil
            ))
            guard (200..<300).contains(response.statusCode),
                  let document = try? JSONDecoder().decode(
                      OAuthDiscoveryDocument.self,
                      from: response.body
                  ),
                  let discoveredAuthorization = URL(
                      string: document.authorizationEndpoint
                  ),
                  let discoveredToken = URL(string: document.tokenEndpoint)
            else {
                throw OAuthHTTPFailure(code: "oauth.discovery_failed")
            }
            try validateDiscoveredURL(
                discoveredAuthorization,
                trustedSuffixes: profile.trustedDiscoveryHostSuffixes
            )
            try validateDiscoveredURL(
                discoveredToken,
                trustedSuffixes: profile.trustedDiscoveryHostSuffixes
            )
            guard let tokenComponents = URLComponents(
                url: discoveredToken,
                resolvingAgainstBaseURL: false
            ), !tokenComponents.path.isEmpty else {
                throw OAuthHTTPFailure(code: "oauth.discovery_failed")
            }
            let tokenBase = URL(
                string: "https://\(try requireHost(discoveredToken))"
            )!
            authorizationURL = discoveredAuthorization
            tokenPath = tokenComponents.path
            tokenEndpoint = try OAuthEndpointProfile(
                id: "\(profile.presetID.rawValue).discovered-token",
                baseURL: tokenBase,
                expectedOrigin: ProviderOAuthProfile.origin(for: tokenBase),
                allowedPaths: [tokenPath]
            )
        } else {
            guard let fixedAuthorization = profile.authorizationURL else {
                throw OAuthHTTPFailure(code: "oauth.authorization_unavailable")
            }
            authorizationURL = fixedAuthorization
            tokenEndpoint = profile.tokenEndpoint
            tokenPath = profile.tokenPath
        }
        let url = try profile.authorizationRequestURL(
            state: state,
            codeChallenge: codeChallenge,
            nonce: profile.presetID == .xAI ? nonce : nil,
            authorizationURL: authorizationURL
        )
        return OAuthAuthorizationPreparation(
            profile: profile,
            authorizationURL: url,
            tokenEndpoint: tokenEndpoint,
            tokenPath: tokenPath,
            state: state,
            codeChallenge: codeChallenge
        )
    }

    public func exchangeDeviceCode(
        profile: OAuthEndpointProfile,
        path: String,
        clientID: String,
        deviceCode: String,
        now: Date = Date()
    ) async throws -> OAuthTokenCredential {
        guard !clientID.isEmpty, !deviceCode.isEmpty else {
            throw OAuthHTTPFailure(code: "oauth.device_code_invalid")
        }
        return try await tokenRequest(
            profile: profile,
            path: path,
            parameters: [
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type":
                    "urn:ietf:params:oauth:grant-type:device_code",
            ],
            preservingRefreshToken: nil,
            now: now
        )
    }

    public func exchangeAuthorizationCode(
        preparation: OAuthAuthorizationPreparation,
        code: String,
        codeVerifier: String,
        now: Date = Date()
    ) async throws -> OAuthTokenCredential {
        let profile = preparation.profile
        guard profile.flow == .authorizationCodePKCE,
              let redirectURI = profile.redirectURI,
              !code.isEmpty,
              !codeVerifier.isEmpty else {
            throw OAuthHTTPFailure(code: "oauth.authorization_code_invalid")
        }
        var parameters = [
            "client_id": profile.clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI.absoluteString,
        ]
        if let clientSecret = profile.clientSecret {
            parameters["client_secret"] = clientSecret
        }
        if profile.presetID == .anthropic {
            parameters["state"] = preparation.state
        }
        if profile.presetID == .xAI {
            parameters["code_challenge"] = preparation.codeChallenge
            parameters["code_challenge_method"] = "S256"
        }
        return try await tokenRequest(
            profile: preparation.tokenEndpoint,
            path: preparation.tokenPath,
            parameters: parameters,
            preservingRefreshToken: nil,
            bodyEncoding: profile.tokenBodyEncoding,
            tokenEndpointURL: endpointURL(
                profile: preparation.tokenEndpoint,
                path: preparation.tokenPath
            ),
            now: now
        )
    }

    public func refresh(
        _ credential: OAuthTokenCredential,
        profile: ProviderOAuthProfile,
        now: Date = Date()
    ) async throws -> OAuthTokenCredential {
        guard let refreshToken = credential.refreshToken else {
            throw OAuthHTTPFailure(code: "oauth.refresh_unavailable")
        }
        var parameters = [
            "client_id": profile.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        if let clientSecret = profile.clientSecret {
            parameters["client_secret"] = clientSecret
        }
        return try await tokenRequest(
            profile: profile.tokenEndpoint,
            path: profile.tokenPath,
            parameters: parameters,
            preservingRefreshToken: refreshToken,
            bodyEncoding: profile.tokenBodyEncoding,
            tokenEndpointURL: credential.tokenEndpointURL,
            now: now
        )
    }

    public func refresh(
        _ credential: OAuthTokenCredential,
        profile: OAuthEndpointProfile,
        path: String,
        clientID: String,
        clientSecret: String? = nil,
        now: Date = Date()
    ) async throws -> OAuthTokenCredential {
        guard let refreshToken = credential.refreshToken,
              !clientID.isEmpty else {
            throw OAuthHTTPFailure(code: "oauth.refresh_unavailable")
        }
        var parameters = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        if let clientSecret, !clientSecret.isEmpty {
            parameters["client_secret"] = clientSecret
        }
        return try await tokenRequest(
            profile: profile,
            path: path,
            parameters: parameters,
            preservingRefreshToken: refreshToken,
            bodyEncoding: .formURLEncoded,
            tokenEndpointURL: credential.tokenEndpointURL,
            now: now
        )
    }

    private func tokenRequest(
        profile: OAuthEndpointProfile,
        path: String,
        parameters: [String: String],
        preservingRefreshToken: String?,
        bodyEncoding: OAuthTokenBodyEncoding = .formURLEncoded,
        tokenEndpointURL: URL? = nil,
        now: Date
    ) async throws -> OAuthTokenCredential {
        let body: Data
        let contentType: String
        switch bodyEncoding {
        case .formURLEncoded:
            body = formBody(parameters)
            contentType = "application/x-www-form-urlencoded"
        case .json:
            body = try JSONSerialization.data(
                withJSONObject: parameters,
                options: [.sortedKeys]
            )
            contentType = "application/json"
        }
        let response = try await send(OAuthHTTPRequest(
            profile: profile,
            method: "POST",
            path: path,
            headers: [
                "content-type": contentType,
            ],
            body: body
        ))
        let value = try? JSONDecoder().decode(
            TokenResponse.self,
            from: response.body
        )
        if let error = value?.error {
            throw OAuthHTTPFailure(code: "oauth.\(error)")
        }
        guard (200..<300).contains(response.statusCode),
              let value,
              let accessToken = value.accessToken,
              !accessToken.isEmpty
        else {
            throw OAuthHTTPFailure(code: "oauth.token_exchange_failed")
        }
        return try OAuthTokenCredential(
            accessToken: accessToken,
            refreshToken: value.refreshToken ?? preservingRefreshToken,
            expiresAt: value.expiresIn.map {
                now.addingTimeInterval($0)
            },
            idToken: value.idToken,
            accountID: value.idToken.flatMap(jwtClaim("chatgpt_account_id")),
            planType: value.idToken.flatMap(jwtClaim("chatgpt_plan_type")),
            tokenEndpointURL: tokenEndpointURL
        )
    }
}

private struct OAuthDiscoveryDocument: Decodable {
    let authorizationEndpoint: String
    let tokenEndpoint: String

    private enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
    }
}

private struct DeviceAuthorizationResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let verificationURIComplete: String?
    let expiresIn: TimeInterval
    let interval: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: TimeInterval?
    let idToken: String?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case idToken = "id_token"
        case error
    }
}

private func validateDiscoveredURL(
    _ url: URL,
    trustedSuffixes: Set<String>
) throws {
    guard let components = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
    ), components.scheme?.lowercased() == "https",
       let host = components.host?.lowercased(),
       components.user == nil,
       components.password == nil,
       components.fragment == nil,
       trustedSuffixes.contains(where: {
           host == $0 || host.hasSuffix(".\($0)")
       })
    else {
        throw OAuthHTTPFailure(code: "oauth.discovery_endpoint_untrusted")
    }
}

private func requireSinglePath(_ paths: Set<String>) throws -> String {
    guard paths.count == 1, let path = paths.first else {
        throw OAuthHTTPFailure(code: "oauth.discovery_failed")
    }
    return path
}

private func requireHost(_ url: URL) throws -> String {
    guard let host = url.host else {
        throw OAuthHTTPFailure(code: "oauth.discovery_failed")
    }
    return host
}

private func endpointURL(
    profile: OAuthEndpointProfile,
    path: String
) -> URL? {
    URL(string: path, relativeTo: profile.baseURL)?.absoluteURL
}

private func jwtClaim(_ name: String) -> (String) -> String? {
    { token in
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var value = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if value.count % 4 != 0 {
            value += String(repeating: "=", count: 4 - value.count % 4)
        }
        guard let data = Data(base64Encoded: value),
              let object = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any]
        else { return nil }
        return object[name] as? String
    }
}

private func formBody(_ values: [String: String]) -> Data {
    var components = URLComponents()
    components.queryItems = values.keys.sorted().map {
        URLQueryItem(name: $0, value: values[$0])
    }
    return Data((components.percentEncodedQuery ?? "").utf8)
}
