import Foundation

public enum WebFetchPolicyDecision: Sendable, Equatable {
    case allowed
    case denied(code: String)
}

/// First-stage public web fetch guard.
///
/// The private-network check is intentionally host-string based: it blocks
/// literal localhost/private IP hosts before URLSession connects, but it does
/// not yet validate the resolved remote address after DNS. Treat this as a
/// best-effort public HTTPS boundary until the fetcher owns resolved-address
/// verification and streaming byte caps.
public struct WebFetchPolicyV1: Sendable, Equatable {
    public var maxResponseBytes: Int
    public var maxExtractedTextCharacters: Int
    public var timeoutSeconds: TimeInterval
    public var maxRedirects: Int

    public static let `default` = WebFetchPolicyV1(
        maxResponseBytes: 512_000,
        maxExtractedTextCharacters: 100_000,
        timeoutSeconds: 20,
        maxRedirects: 5
    )

    public init(
        maxResponseBytes: Int,
        maxExtractedTextCharacters: Int,
        timeoutSeconds: TimeInterval,
        maxRedirects: Int
    ) {
        self.maxResponseBytes = maxResponseBytes
        self.maxExtractedTextCharacters = maxExtractedTextCharacters
        self.timeoutSeconds = timeoutSeconds
        self.maxRedirects = maxRedirects
    }

    public func validate(_ request: URLRequest) -> WebFetchPolicyDecision {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased()
        else {
            return .denied(code: "web_fetch.invalid_url")
        }
        guard scheme == "https" else {
            return .denied(code: "web_fetch.scheme_denied")
        }
        guard (url.user?.isEmpty ?? true),
              (url.password?.isEmpty ?? true)
        else {
            return .denied(code: "web_fetch.credentials_denied")
        }
        guard request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil
        else {
            return .denied(code: "web_fetch.credentials_denied")
        }
        guard !isPrivateHost(url.host(percentEncoded: false) ?? "") else {
            return .denied(code: "web_fetch.private_network_denied")
        }
        return .allowed
    }

    public func validateRedirect(
        from: URLRequest,
        to redirectedRequest: URLRequest,
        redirectCount: Int
    ) -> WebFetchPolicyDecision {
        guard redirectCount <= maxRedirects else {
            return .denied(code: "web_fetch.redirect_limit_exceeded")
        }
        return validate(redirectedRequest)
    }

    public func allowsMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else {
            return false
        }
        return mimeType.hasPrefix("text/")
            || mimeType == "application/json"
            || mimeType == "application/ld+json"
    }

    private func isPrivateHost(_ host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lower == "localhost" || lower.hasSuffix(".local") {
            return true
        }
        if lower == "::1" || lower == "0:0:0:0:0:0:0:1" {
            return true
        }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") {
            return true
        }
        if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") {
            return true
        }
        if lower.hasPrefix("::ffff:") {
            return isPrivateHost(String(lower.dropFirst("::ffff:".count)))
        }
        if lower.hasPrefix("127.") || lower.hasPrefix("10.") || lower.hasPrefix("192.168.") {
            return true
        }
        if lower.hasPrefix("169.254.") {
            return true
        }
        if lower.hasPrefix("172.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2,
               let second = Int(parts[1]),
               (16...31).contains(second) {
                return true
            }
        }
        return false
    }
}
