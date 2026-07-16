import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("Authorized exact-origin cloud transport", .serialized)
struct CloudHTTPTransportTests {
    @Test(arguments: [
        CloudIPAddress.ipv4("0.0.0.0"),
        .ipv4("10.20.30.40"),
        .ipv4("100.64.0.1"),
        .ipv4("127.0.0.1"),
        .ipv4("169.254.1.1"),
        .ipv4("172.16.0.1"),
        .ipv4("192.0.0.1"),
        .ipv4("192.0.2.1"),
        .ipv4("192.168.1.1"),
        .ipv4("198.18.0.1"),
        .ipv4("198.51.100.1"),
        .ipv4("203.0.113.1"),
        .ipv4("224.0.0.1"),
        .ipv4("240.0.0.1"),
        .ipv6("::"),
        .ipv6("::1"),
        .ipv6("::ffff:127.0.0.1"),
        .ipv6("100::1"),
        .ipv6("2001:db8::1"),
        .ipv6("fc00::1"),
        .ipv6("fe80::1"),
        .ipv6("ff02::1"),
    ])
    func reservedAddressesAreNeverEligibleForProviderEgress(_ address: CloudIPAddress) {
        #expect(!CloudTransportPolicy.isGloballyRoutable(address))
    }

    @Test(arguments: [
        CloudIPAddress.ipv4("1.1.1.1"),
        .ipv4("8.8.8.8"),
        .ipv6("2606:4700:4700::1111"),
        .ipv6("2001:4860:4860::8888"),
    ])
    func ordinaryPublicAddressesAreEligibleForPreflight(_ address: CloudIPAddress) {
        #expect(CloudTransportPolicy.isGloballyRoutable(address))
    }

    @Test
    func validatorRejectsUnsafeURLShapesAndMixedDNSAnswers() async throws {
        let resolver = ScriptedCloudResolver(answers: [[
            .ipv4("1.1.1.1"), .ipv4("127.0.0.1"),
        ]])
        let validator = StablePublicOriginValidator(resolver: resolver)

        await expectTransportFailure("cloud_transport.origin_forbidden") {
            _ = try await validator.validate(URL(string: "https://api.example.com/v1")!)
        }
        for value in [
            "http://api.example.com/v1",
            "https://user:pass@api.example.com/v1",
            "https://api.example.com/v1#fragment",
            "https://127.0.0.1/v1",
            "https://[::1]/v1",
        ] {
            await expectTransportFailure("cloud_transport.origin_forbidden") {
                _ = try await StablePublicOriginValidator(
                    resolver: ScriptedCloudResolver(answers: [[.ipv4("1.1.1.1")]])
                ).validate(URL(string: value)!)
            }
        }
    }

    @Test
    func validatorNormalizesOnePublicExactOrigin() async throws {
        let validator = StablePublicOriginValidator(
            resolver: ScriptedCloudResolver(answers: [[.ipv4("1.1.1.1")]])
        )
        let origin = try await validator.validate(URL(string: "https://API.Example.COM/v1")!)
        #expect(origin == EgressOrigin(scheme: "https", host: "api.example.com", port: 443))
    }

    @Test
    func redirectsStayOnExactOriginAndBasePath() throws {
        let policy = CloudTransportPolicy(
            resolver: ScriptedCloudResolver(answers: [[.ipv4("1.1.1.1")]])
        )
        let origin = EgressOrigin(scheme: "https", host: "api.example.com", port: 443)
        let base = URL(string: "https://api.example.com/v1")!

        try policy.validateRedirect(
            URL(string: "https://api.example.com/v1/responses?page=2")!,
            expectedOrigin: origin,
            baseURL: base,
            redirectCount: 1
        )
        for value in [
            "https://other.example.com/v1/responses",
            "http://api.example.com/v1/responses",
            "https://user:pass@api.example.com/v1/responses",
            "https://api.example.com/outside",
        ] {
            expectSynchronousTransportFailure("cloud_transport.redirect_forbidden") {
                try policy.validateRedirect(
                    URL(string: value)!,
                    expectedOrigin: origin,
                    baseURL: base,
                    redirectCount: 1
                )
            }
        }
        expectSynchronousTransportFailure("cloud_transport.redirect_limit") {
            try policy.validateRedirect(
                URL(string: "https://api.example.com/v1/responses")!,
                expectedOrigin: origin,
                baseURL: base,
                redirectCount: 4
            )
        }
    }

    @Test
    func changedToPrivatePreflightAnswerFailsBeforeRequestCreation() async throws {
        let resolver = ScriptedCloudResolver(answers: [
            [.ipv4("1.1.1.1")],
            [.ipv4("127.0.0.1")],
        ])
        let validator = StablePublicOriginValidator(resolver: resolver)
        let baseURL = URL(string: "https://api.example.com/v1")!
        let origin = try await validator.validate(baseURL)
        let policy = CloudTransportPolicy(resolver: resolver)

        await expectTransportFailure("cloud_transport.origin_forbidden") {
            try await policy.preflight(baseURL: baseURL, expectedOrigin: origin)
        }
        #expect(await resolver.resolveCount == 2)
    }

    @Test
    func authorizedStreamBuildsExactURLInjectsCredentialAndParsesIncrementally() async throws {
        let fixture = try await makeAuthorizedTransportFixture()
        defer { fixture.cleanup(); CloudURLProtocolStub.reset() }
        let fixtureBytes = try Data(contentsOf: try #require(
            Bundle.module.url(
                forResource: "fragmented-stream",
                withExtension: "sse"
            )
        ))
        let split = try #require(fixtureBytes.firstRange(of: Data("lo\n\n".utf8))?.lowerBound)
        CloudURLProtocolStub.install { request in
            #expect(request.url?.absoluteString == "https://api.example.com/v1/responses?mode=stream")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key")
            #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
            let transmittedBody = try requestBody(request)
            #expect(transmittedBody == Data("{\"stream\":true}".utf8))
            return .response(
                status: 200,
                headers: ["content-type": "text/event-stream"],
                chunks: [
                    fixtureBytes.prefix(split + 1),
                    fixtureBytes.dropFirst(split + 1),
                ]
            )
        }
        let transport = URLSessionCloudHTTPTransport(
            credentialStore: fixture.credentials,
            policy: CloudTransportPolicy(
                resolver: ScriptedCloudResolver(answers: [[.ipv4("1.1.1.1")]])
            ),
            configuration: cloudStubConfiguration()
        )

        let events = try await collect(try await transport.stream(fixture.request))

        #expect(events.map { String(decoding: $0.data, as: UTF8.self) } == ["hello", "second"])
        #expect(CloudURLProtocolStub.startedCount == 1)
        #expect(await fixture.credentialLoadCount() == 1)
    }

    @Test
    func authorizedJSONIsBoundedAndUsesTheSamePolicyBoundary() async throws {
        let fixture = try await makeAuthorizedTransportFixture()
        defer { fixture.cleanup(); CloudURLProtocolStub.reset() }
        CloudURLProtocolStub.install { _ in
            .response(
                status: 200,
                headers: ["content-type": "application/json"],
                chunks: [Data("{\"ok\":true}".utf8)]
            )
        }
        let transport = makeStubTransport(fixture)

        #expect(try await transport.json(fixture.request) == Data("{\"ok\":true}".utf8))

        CloudURLProtocolStub.install { _ in
            .response(status: 200, headers: [:], chunks: [Data(repeating: 0x61, count: 1_025)])
        }
        let smallLimitTransport = makeStubTransport(fixture, maximumJSONBytes: 1_024)
        await expectTransportFailure("cloud_transport.response_too_large") {
            try await smallLimitTransport.json(fixture.request)
        }
    }

    @Test
    func successfulStreamingResponseMustActuallyBeSSE() async throws {
        let fixture = try await makeAuthorizedTransportFixture()
        defer { fixture.cleanup(); CloudURLProtocolStub.reset() }
        CloudURLProtocolStub.install { _ in
            .response(
                status: 200,
                headers: ["content-type": "application/json"],
                chunks: [Data("{\"not\":\"sse\"}".utf8)]
            )
        }
        let transport = makeStubTransport(fixture)
        do {
            _ = try await collect(try await transport.stream(fixture.request))
            Issue.record("expected content-type failure")
        } catch let failure as LLMFailure {
            #expect(failure.code == "cloud_transport.content_type_invalid")
            #expect(failure.redactedDiagnostics.isEmpty)
        }
    }

    @Test
    func HTTPFailuresMapToProviderNeutralCodesAndNeverEchoBodiesOrHeaders() async throws {
        let fixture = try await makeAuthorizedTransportFixture()
        defer { fixture.cleanup(); CloudURLProtocolStub.reset() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let retryDate = httpDate(now.addingTimeInterval(90))
        let errorBody = try Data(contentsOf: try #require(
            Bundle.module.url(
                forResource: "error-response",
                withExtension: "json"
            )
        ))
        let cases: [(Int, [String: String], String, Bool, String?)] = [
            (401, [:], "cloud_transport.unauthorized", false, nil),
            (403, [:], "cloud_transport.forbidden", false, nil),
            (404, [:], "cloud_transport.model_missing", false, nil),
            (429, ["retry-after": "120"], "cloud_transport.rate_limited", true, "120"),
            (429, ["retry-after": retryDate], "cloud_transport.rate_limited", true, "90"),
            (503, [:], "cloud_transport.provider_unavailable", true, nil),
        ]
        for (status, extraHeaders, expectedCode, retryable, retryAfter) in cases {
            var headers = extraHeaders
            headers["content-type"] = "application/json"
            headers["x-request-id"] = "req_safe-1"
            let responseHeaders = headers
            CloudURLProtocolStub.install { _ in
                .response(
                    status: status,
                    headers: responseHeaders,
                    chunks: [errorBody]
                )
            }
            let transport = makeStubTransport(fixture, clock: { now })
            do {
                _ = try await transport.json(fixture.request)
                Issue.record("expected HTTP failure for status \(status)")
            } catch let failure as LLMFailure {
                #expect(failure.code == expectedCode)
                #expect(failure.retryable == retryable)
                #expect(failure.redactedDiagnostics["provider_semantic_id"] == "openai.responses")
                #expect(failure.redactedDiagnostics["status_class"] == "\(status / 100)xx")
                #expect(failure.redactedDiagnostics["request_id"] == "req_safe-1")
                #expect(failure.redactedDiagnostics["retry_after_seconds"] == retryAfter)
                let serialized = try JSONEncoder().encode(failure)
                #expect(!String(decoding: serialized, as: UTF8.self).contains("SECRET"))
                #expect(!String(decoding: serialized, as: UTF8.self).contains("api.example.com"))
                #expect(!String(decoding: serialized, as: UTF8.self).contains("test-only-key"))
            }
        }
    }

    @Test
    func changedToPrivateImmediatePreflightStopsBeforeCredentialAndURLSession() async throws {
        let fixture = try await makeAuthorizedTransportFixture()
        defer { fixture.cleanup(); CloudURLProtocolStub.reset() }
        CloudURLProtocolStub.install { _ in
            .response(status: 200, headers: [:], chunks: [])
        }
        let transport = URLSessionCloudHTTPTransport(
            credentialStore: fixture.credentials,
            policy: CloudTransportPolicy(
                resolver: ScriptedCloudResolver(answers: [[.ipv4("127.0.0.1")]])
            ),
            configuration: cloudStubConfiguration()
        )

        await expectTransportFailure("cloud_transport.origin_forbidden") {
            try await transport.stream(fixture.request)
        }

        #expect(CloudURLProtocolStub.startedCount == 0)
        #expect(await fixture.credentialLoadCount() == 0)
    }

    @Test
    func cancellingAConsumerCancelsTheUnderlyingURLSessionTask() async throws {
        let fixture = try await makeAuthorizedTransportFixture()
        defer { fixture.cleanup(); CloudURLProtocolStub.reset() }
        CloudURLProtocolStub.install { _ in .never }
        let transport = makeStubTransport(fixture)
        let stream = try await transport.stream(fixture.request)
        let consumer = Task {
            for try await _ in stream {}
        }
        await waitUntil { CloudURLProtocolStub.startedCount == 1 }

        consumer.cancel()
        _ = try? await consumer.value
        await waitUntil { CloudURLProtocolStub.stoppedCount == 1 }

        #expect(CloudURLProtocolStub.stoppedCount == 1)
    }
}

private actor ScriptedCloudResolver: CloudHostResolving {
    private var answers: [[CloudIPAddress]]
    private(set) var resolveCount = 0

    init(answers: [[CloudIPAddress]]) { self.answers = answers }

    func resolve(_ host: String) async throws -> [CloudIPAddress] {
        _ = host
        resolveCount += 1
        guard !answers.isEmpty else { return [] }
        return answers.removeFirst()
    }
}

private func makeStubTransport(
    _ fixture: AuthorizedTransportFixture,
    maximumJSONBytes: Int = 8 * 1_024 * 1_024,
    clock: @escaping @Sendable () -> Date = Date.init
) -> URLSessionCloudHTTPTransport {
    URLSessionCloudHTTPTransport(
        credentialStore: fixture.credentials,
        policy: CloudTransportPolicy(
            resolver: ScriptedCloudResolver(answers: [[.ipv4("1.1.1.1")]])
        ),
        configuration: cloudStubConfiguration(),
        maximumJSONBytes: maximumJSONBytes,
        clock: clock
    )
}

private func cloudStubConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudURLProtocolStub.self]
    return configuration
}

private func collect(
    _ stream: AsyncThrowingStream<SSEEvent, Error>
) async throws -> [SSEEvent] {
    var values: [SSEEvent] = []
    for try await value in stream { values.append(value) }
    return values
}

private func httpDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
    return formatter.string(from: date)
}

private func requestBody(_ request: URLRequest) throws -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async {
    for _ in 0..<2_000 {
        if predicate() { return }
        await Task.yield()
    }
}

private enum CloudURLProtocolResult: Sendable {
    case response(status: Int, headers: [String: String], chunks: [Data])
    case never
}

private final class CloudURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> CloudURLProtocolResult)?
    private var started = 0
    private var stopped = 0

    func install(_ handler: @escaping @Sendable (URLRequest) throws -> CloudURLProtocolResult) {
        lock.lock()
        self.handler = handler
        started = 0
        stopped = 0
        lock.unlock()
    }

    func reset() {
        lock.lock()
        handler = nil
        started = 0
        stopped = 0
        lock.unlock()
    }

    func start(_ request: URLRequest) throws -> CloudURLProtocolResult {
        lock.lock()
        started += 1
        let handler = handler
        lock.unlock()
        guard let handler else { throw URLError(.unsupportedURL) }
        return try handler(request)
    }

    func stop() {
        lock.lock()
        stopped += 1
        lock.unlock()
    }

    var counts: (started: Int, stopped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (started, stopped)
    }
}

private final class CloudURLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let state = CloudURLProtocolState()

    static var startedCount: Int { state.counts.started }
    static var stoppedCount: Int { state.counts.stopped }
    static func install(_ handler: @escaping @Sendable (URLRequest) throws -> CloudURLProtocolResult) {
        state.install(handler)
    }
    static func reset() { state.reset() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            switch try Self.state.start(request) {
            case let .response(status, headers, chunks):
                guard let url = request.url else {
                    throw URLError(.badURL)
                }
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
                client?.urlProtocolDidFinishLoading(self)
            case .never:
                break
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { Self.state.stop() }
}

private func expectTransportFailure<T: Sendable>(
    _ code: String,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("expected LLMFailure with code \(code)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private func expectSynchronousTransportFailure(
    _ code: String,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("expected LLMFailure with code \(code)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
