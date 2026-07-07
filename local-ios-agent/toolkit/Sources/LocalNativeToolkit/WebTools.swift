import Foundation
import LocalAgentBridge

public struct WebFetchResponse: Sendable {
    public var data: Data
    public var response: URLResponse
    public var redirectChain: [URLRequest]

    public init(data: Data, response: URLResponse, redirectChain: [URLRequest]) {
        self.data = data
        self.response = response
        self.redirectChain = redirectChain
    }
}

public protocol WebFetching: Sendable {
    func fetch(_ request: URLRequest, policy: WebFetchPolicyV1) async throws -> WebFetchResponse
}

public struct URLSessionWebFetcher: WebFetching {
    public init() {}

    public func fetch(_ request: URLRequest, policy: WebFetchPolicyV1) async throws -> WebFetchResponse {
        let delegate = RedirectRecordingDelegate(policy: policy)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer {
            session.invalidateAndCancel()
        }
        let (data, response) = try await session.data(for: request)
        if let code = delegate.redirectFailureCode {
            throw WebFetchError.policyDenied(code)
        }
        return WebFetchResponse(data: data, response: response, redirectChain: delegate.redirectChain)
    }
}

public enum WebFetchError: Error, Sendable, Equatable {
    case policyDenied(String)
}

private final class RedirectRecordingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let policy: WebFetchPolicyV1
    private var redirectCount: Int = 0
    private var storedRedirectChain: [URLRequest] = []
    private var storedFailureCode: String?

    var redirectChain: [URLRequest] {
        withLock { storedRedirectChain }
    }

    var redirectFailureCode: String? {
        withLock { storedFailureCode }
    }

    init(policy: WebFetchPolicyV1) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let count = withLock {
            redirectCount += 1
            storedRedirectChain.append(request)
            return redirectCount
        }

        let decision = policy.validateRedirect(
            from: task.originalRequest ?? request,
            to: request,
            redirectCount: count
        )
        switch decision {
        case .allowed:
            completionHandler(request)
        case .denied(let code):
            withLock {
                storedFailureCode = code
            }
            completionHandler(nil)
        }
    }

    private func withLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return work()
    }
}

public struct WebFetchURLTextTool: NativeTool {
    public let schema: NativeToolSchema
    private let policy: WebFetchPolicyV1
    private let fetcher: any WebFetching

    public init(
        policy: WebFetchPolicyV1 = .default,
        fetcher: any WebFetching = URLSessionWebFetcher()
    ) {
        self.policy = policy
        self.fetcher = fetcher
        let manifest = NativeToolManifest(
            manifestId: "native.web.fetch_url_text.v1",
            capabilityId: "web.fetch_url_text",
            title: "Fetch URL Text",
            description: "Fetch bounded text from a public HTTPS URL.",
            mode: .background,
            permissionScope: NativePermissionScope("web.fetch.approved"),
            requiredPrivacyKeys: [],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(
                kind: .unavailable,
                message: "The URL cannot be fetched under the web fetch policy."
            ),
            riskLevel: .confirm,
            approvalPolicy: .perCall,
            trustLevel: .untrustedExternalContent,
            retention: .runOnly,
            audit: NativeToolAudit(label: "Web Fetch", resultSummaryPolicy: .excerptOnly)
        )
        self.schema = NativeToolSchema(
            name: "web.fetch_url_text",
            description: manifest.description,
            inputSchema: .object(properties: ["url": .string()], required: ["url"]),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        guard let url = Self.decodeURL(argumentsJson) else {
            return NativeToolResultBuilder.error(
                manifestId: "native.web.fetch_url_text.v1",
                toolName: "web.fetch_url_text",
                toolCallId: "unknown",
                code: "web_fetch.invalid_arguments",
                displayText: "Expected a URL string.",
                auditSummary: "Web fetch failed: invalid arguments"
            )
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = policy.timeoutSeconds
        request.httpShouldHandleCookies = false
        request.setValue("text/html, text/plain, application/json", forHTTPHeaderField: "Accept")

        switch policy.validate(request) {
        case .allowed:
            break
        case .denied(let code):
            return blockedResult(code: code, displayText: "This URL is blocked by the web fetch policy.")
        }

        do {
            let fetched = try await fetcher.fetch(request, policy: policy)
            for redirect in fetched.redirectChain {
                switch policy.validate(redirect) {
                case .allowed:
                    break
                case .denied(let code):
                    return blockedResult(code: code, displayText: "A redirect was blocked by the web fetch policy.")
                }
            }
            guard fetched.data.count <= policy.maxResponseBytes else {
                return blockedResult(code: "web_fetch.response_too_large", displayText: "The response is too large.")
            }
            if let http = fetched.response as? HTTPURLResponse,
               !policy.allowsMimeType(http.mimeType) {
                return blockedResult(code: "web_fetch.mime_denied", displayText: "The response type is not allowed.")
            }
            let text = String(decoding: fetched.data, as: UTF8.self)
            let excerpt = String(text.prefix(policy.maxExtractedTextCharacters))
            return NativeToolResultBuilder.success(
                manifestId: "native.web.fetch_url_text.v1",
                toolName: "web.fetch_url_text",
                toolCallId: "unknown",
                displayText: "Fetched text from \(url.host() ?? url.absoluteString)",
                modelText: "External web content from \(url.absoluteString):\n\(excerpt)",
                resultKind: "web_text",
                resultPayload: [
                    "url": .string(url.absoluteString),
                    "text_excerpt": .string(excerpt),
                    "truncated": .bool(excerpt.count < text.count),
                ],
                sourceKind: "web",
                sourceId: url.absoluteString,
                displayName: url.host() ?? url.absoluteString,
                attachmentIds: [],
                trustLevel: .untrustedExternalContent,
                sensitivity: .public,
                retention: .runOnly,
                modelTextPolicy: "summarize_or_quote_only",
                sourceLabel: "Web",
                auditSummary: "Fetched text from \(url.absoluteString)",
                auditRedaction: "excerpt_only"
            )
        } catch {
            return blockedResult(code: "web_fetch.network_error", displayText: "The URL could not be fetched.")
        }
    }

    private func blockedResult(code: String, displayText: String) -> ToolResultDTO {
        NativeToolResultBuilder.error(
            manifestId: "native.web.fetch_url_text.v1",
            toolName: "web.fetch_url_text",
            toolCallId: "unknown",
            code: code,
            displayText: displayText,
            auditSummary: "Web fetch blocked: \(code)"
        )
    }

    private static func decodeURL(_ argumentsJson: String) -> URL? {
        guard let data = argumentsJson.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["url"] as? String
        else {
            return nil
        }
        return URL(string: value)
    }
}
