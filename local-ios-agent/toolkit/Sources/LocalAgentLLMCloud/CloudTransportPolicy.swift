import Darwin
import Foundation
import LocalAgentLLMContracts

package enum CloudIPAddress: Hashable, Sendable {
    case ipv4(String)
    case ipv6(String)
}

package protocol CloudHostResolving: Sendable {
    func resolve(_ host: String) async throws -> [CloudIPAddress]
}

package struct SystemCloudHostResolver: CloudHostResolving {
    package init() {}

    package func resolve(_ host: String) async throws -> [CloudIPAddress] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var head: UnsafeMutablePointer<addrinfo>?
        let result = getaddrinfo(host, nil, &hints, &head)
        guard result == 0 else {
            throw transportFailure(
                "cloud_transport.dns_failed",
                "provider hostname could not be resolved",
                retryable: true
            )
        }
        defer { if let head { freeaddrinfo(head) } }
        var addresses = Set<CloudIPAddress>()
        var cursor = head
        while let current = cursor {
            let info = current.pointee
            if info.ai_family == AF_INET,
               let address = info.ai_addr?.withMemoryRebound(
                   to: sockaddr_in.self,
                   capacity: 1,
                   { $0.pointee.sin_addr }
               ),
               let text = presentationAddress(address, family: AF_INET) {
                addresses.insert(.ipv4(text))
            } else if info.ai_family == AF_INET6,
                      let address = info.ai_addr?.withMemoryRebound(
                          to: sockaddr_in6.self,
                          capacity: 1,
                          { $0.pointee.sin6_addr }
                      ),
                      let text = presentationAddress(address, family: AF_INET6) {
                addresses.insert(.ipv6(text))
            }
            cursor = info.ai_next
        }
        return addresses.sorted { $0.sortKey < $1.sortKey }
    }
}

package struct StablePublicOriginValidator: ProviderOriginValidating {
    private let policy: CloudTransportPolicy

    package init(resolver: any CloudHostResolving = SystemCloudHostResolver()) {
        policy = CloudTransportPolicy(resolver: resolver)
    }

    package func validate(_ baseURL: URL) async throws -> EgressOrigin {
        try await policy.validateBaseURL(baseURL)
    }
}

/// Validates an arbitrary outbound HTTPS URL with the same DNS and reserved
/// address checks used by the cloud model transport.
public struct PublicNetworkURLValidator: Sendable {
    private let policy = CloudTransportPolicy()

    public init() {}

    public func validate(_ url: URL) async throws {
        try await policy.validatePublicURL(url)
    }
}

package struct CloudTransportPolicy: Sendable {
    private let resolver: any CloudHostResolving
    package let maximumRedirects: Int

    package init(
        resolver: any CloudHostResolving = SystemCloudHostResolver(),
        maximumRedirects: Int = 3
    ) {
        self.resolver = resolver
        self.maximumRedirects = maximumRedirects
    }

    package func validateBaseURL(_ baseURL: URL) async throws -> EgressOrigin {
        let origin = try Self.normalizedOrigin(baseURL, allowQuery: false)
        try Self.validateWirePath(baseURL.path)
        try await requirePublicAnswers(host: origin.host)
        return origin
    }

    package func validatePublicURL(_ url: URL) async throws {
        let origin = try Self.normalizedOrigin(url, allowQuery: true)
        try Self.validateWirePath(url.path)
        try await requirePublicAnswers(host: origin.host)
    }

    package func preflight(baseURL: URL, expectedOrigin: EgressOrigin) async throws {
        let current = try Self.normalizedOrigin(baseURL, allowQuery: false)
        guard current == expectedOrigin else {
            throw transportFailure(
                "cloud_transport.origin_changed",
                "provider origin no longer matches its authorization"
            )
        }
        try Self.validateWirePath(baseURL.path)
        try await requirePublicAnswers(host: expectedOrigin.host)
    }

    package func validateRedirect(
        _ url: URL,
        expectedOrigin: EgressOrigin,
        baseURL: URL,
        redirectCount: Int
    ) throws {
        guard redirectCount > 0, redirectCount <= maximumRedirects else {
            throw transportFailure(
                "cloud_transport.redirect_limit",
                "provider redirect limit was exceeded"
            )
        }
        let redirectedOrigin: EgressOrigin
        do {
            redirectedOrigin = try Self.normalizedOrigin(url, allowQuery: true)
            try Self.validateWirePath(url.path)
        } catch {
            throw transportFailure(
                "cloud_transport.redirect_forbidden",
                "provider redirect target was rejected"
            )
        }
        let basePath = Self.normalizedBasePath(baseURL.path)
        let redirectedPath = Self.normalizedBasePath(url.path)
        guard redirectedOrigin == expectedOrigin,
              redirectedPath == basePath || redirectedPath.hasPrefix(basePath + "/")
        else {
            throw transportFailure(
                "cloud_transport.redirect_forbidden",
                "provider redirect target was rejected"
            )
        }
    }

    package static func isGloballyRoutable(_ address: CloudIPAddress) -> Bool {
        switch address {
        case let .ipv4(text):
            guard let value = parseIPv4(text) else { return false }
            return !ipv4ForbiddenRanges.contains { value & $0.mask == $0.network }
        case let .ipv6(text):
            guard let bytes = parseIPv6(text) else { return false }
            return !ipv6ForbiddenPrefixes.contains { matches(bytes, prefix: $0.bytes, bits: $0.bits) }
        }
    }

    private func requirePublicAnswers(host: String) async throws {
        let literal = Self.literalAddress(host)
        let addresses: [CloudIPAddress]
        if let literal {
            addresses = [literal]
        } else {
            addresses = try await resolver.resolve(host)
        }
        guard !addresses.isEmpty, addresses.allSatisfy(Self.isGloballyRoutable) else {
            throw transportFailure(
                "cloud_transport.origin_forbidden",
                "provider hostname did not resolve exclusively to public addresses"
            )
        }
    }

    private static func normalizedOrigin(_ url: URL, allowQuery: Bool) throws -> EgressOrigin {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host,
              !rawHost.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              allowQuery || components.query == nil,
              !rawHost.hasSuffix(".")
        else {
            throw transportFailure(
                "cloud_transport.origin_forbidden",
                "provider base URL must use a credential-free HTTPS origin"
            )
        }
        let host = rawHost.lowercased()
        let port = components.port ?? 443
        guard (1...65_535).contains(port), let exactPort = UInt16(exactly: port) else {
            throw transportFailure("cloud_transport.origin_forbidden", "provider port is invalid")
        }
        return EgressOrigin(scheme: "https", host: host, port: exactPort)
    }

    package static func validateWirePath(_ path: String) throws {
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            let decoded = String(component).removingPercentEncoding ?? String(component)
            guard decoded != ".", decoded != "..", !decoded.contains("\0") else {
                throw transportFailure("cloud_transport.path_forbidden", "provider path is invalid")
            }
        }
    }

    package static func normalizedBasePath(_ path: String) -> String {
        guard path.count > 1 else { return "" }
        var value = path
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func literalAddress(_ host: String) -> CloudIPAddress? {
        let unwrapped = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        if parseIPv4(unwrapped) != nil { return .ipv4(unwrapped) }
        if parseIPv6(unwrapped) != nil { return .ipv6(unwrapped) }
        return nil
    }
}

private let ipv4ForbiddenRanges: [(network: UInt32, mask: UInt32)] = [
    (0x0000_0000, 0xFF00_0000), // current network / unspecified
    (0x0A00_0000, 0xFF00_0000), // RFC 1918
    (0x6440_0000, 0xFFC0_0000), // shared address space
    (0x7F00_0000, 0xFF00_0000), // loopback
    (0xA9FE_0000, 0xFFFF_0000), // link-local
    (0xAC10_0000, 0xFFF0_0000), // RFC 1918
    (0xC000_0000, 0xFFFF_FF00), // IETF protocol assignments
    (0xC000_0200, 0xFFFF_FF00), // documentation
    (0xC058_6300, 0xFFFF_FF00), // deprecated 6to4 relay anycast
    (0xC0A8_0000, 0xFFFF_0000), // RFC 1918
    (0xC612_0000, 0xFFFE_0000), // benchmark
    (0xC633_6400, 0xFFFF_FF00), // documentation
    (0xCB00_7100, 0xFFFF_FF00), // documentation
    (0xE000_0000, 0xF000_0000), // multicast
    (0xF000_0000, 0xF000_0000), // reserved / broadcast
]

private let ipv6ForbiddenPrefixes: [(bytes: [UInt8], bits: Int)] = [
    ([0x00], 8), // unspecified, loopback, IPv4-compatible/mapped
    ([0x00, 0x64, 0xFF, 0x9B, 0x00, 0x01], 48), // local-use translation
    ([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], 64), // discard-only
    ([0x20, 0x01, 0x00, 0x00], 32), // Teredo
    ([0x20, 0x01, 0x00, 0x02, 0x00, 0x00], 48), // benchmark
    ([0x20, 0x01, 0x00, 0x10], 28), // ORCHIDv1
    ([0x20, 0x01, 0x00, 0x20], 28), // ORCHIDv2
    ([0x20, 0x01, 0x0D, 0xB8], 32), // documentation
    ([0x3F, 0xFF, 0x00], 20), // documentation
    ([0x5F, 0x00], 16), // segment-routing local block
    ([0xFC], 7), // unique local
    ([0xFE, 0x80], 10), // link-local
    ([0xFF], 8), // multicast
]

private func parseIPv4(_ text: String) -> UInt32? {
    var address = in_addr()
    guard text.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
    return UInt32(bigEndian: address.s_addr)
}

private func parseIPv6(_ text: String) -> [UInt8]? {
    var address = in6_addr()
    guard text.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
    return withUnsafeBytes(of: &address) { Array($0) }
}

private func matches(_ bytes: [UInt8], prefix: [UInt8], bits: Int) -> Bool {
    guard bytes.count == 16, bits <= prefix.count * 8 else { return false }
    let fullBytes = bits / 8
    if fullBytes > 0, Array(bytes[..<fullBytes]) != Array(prefix[..<fullBytes]) { return false }
    let remaining = bits % 8
    guard remaining > 0 else { return true }
    let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - remaining))
    return bytes[fullBytes] & mask == prefix[fullBytes] & mask
}

private func presentationAddress<Address>(_ address: Address, family: Int32) -> String? {
    var value = address
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    return withUnsafePointer(to: &value) { pointer in
        guard inet_ntop(family, pointer, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private extension CloudIPAddress {
    var sortKey: String {
        switch self {
        case let .ipv4(value): "4:\(value)"
        case let .ipv6(value): "6:\(value)"
        }
    }
}

package func transportFailure(
    _ code: String,
    _ message: String,
    retryable: Bool = false,
    recoveryAction: LLMRecoveryAction? = nil,
    redactedDiagnostics: [String: String] = [:]
) -> LLMFailure {
    LLMFailure(
        code: code,
        message: message,
        retryable: retryable,
        recoveryAction: recoveryAction,
        redactedDiagnostics: redactedDiagnostics
    )
}
