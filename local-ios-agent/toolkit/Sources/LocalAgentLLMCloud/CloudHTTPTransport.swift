import Foundation
import LocalAgentLLMContracts

package protocol CloudHTTPTransport: Sendable {
    func stream(
        _ request: AuthorizedCloudHTTPRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error>

    func json(_ request: AuthorizedCloudHTTPRequest) async throws -> Data
}

package final class URLSessionCloudHTTPTransport: CloudHTTPTransport, @unchecked Sendable {
    private let credentialStore: ProviderCredentialStore
    private let policy: CloudTransportPolicy
    private let configuration: URLSessionConfiguration
    private let maximumJSONBytes: Int
    private let maximumErrorBytes: Int
    private let clock: @Sendable () -> Date

    package init(
        credentialStore: ProviderCredentialStore,
        policy: CloudTransportPolicy = CloudTransportPolicy(),
        configuration: URLSessionConfiguration = .ephemeral,
        maximumJSONBytes: Int = 8 * 1_024 * 1_024,
        maximumErrorBytes: Int = 16 * 1_024,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialStore = credentialStore
        self.policy = policy
        let isolated = configuration.copy() as! URLSessionConfiguration
        isolated.urlCache = nil
        isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
        isolated.httpCookieStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.timeoutIntervalForRequest = 30
        isolated.timeoutIntervalForResource = 300
        isolated.httpMaximumConnectionsPerHost = 1
        self.configuration = isolated
        self.maximumJSONBytes = maximumJSONBytes
        self.maximumErrorBytes = maximumErrorBytes
        self.clock = clock
    }

    package func stream(
        _ request: AuthorizedCloudHTTPRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        try validateLimits()
        let lease = try await validateBeforeTask(request)
        try await policy.preflight(baseURL: request.baseURL, expectedOrigin: request.origin)
        return try await withCredential(request: request, lease: lease) { urlRequest in
            let pair = AsyncThrowingStream<SSEEvent, Error>.makeStream(
                bufferingPolicy: .bufferingOldest(8)
            )
            let delegate = CloudURLSessionResponseDelegate(
                request: request,
                policy: self.policy,
                maximumErrorBytes: self.maximumErrorBytes,
                clock: self.clock,
                sseContinuation: pair.continuation
            )
            self.start(urlRequest, delegate: delegate)
            pair.continuation.onTermination = { @Sendable [weak delegate] _ in
                delegate?.cancelFromConsumer()
            }
            return pair.stream
        }
    }

    package func json(_ request: AuthorizedCloudHTTPRequest) async throws -> Data {
        try validateLimits()
        let lease = try await validateBeforeTask(request)
        try await policy.preflight(baseURL: request.baseURL, expectedOrigin: request.origin)
        let stream = try await withCredential(request: request, lease: lease) { urlRequest in
            let pair = AsyncThrowingStream<Data, Error>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let delegate = CloudURLSessionResponseDelegate(
                request: request,
                policy: self.policy,
                maximumErrorBytes: self.maximumErrorBytes,
                clock: self.clock,
                maximumJSONBytes: self.maximumJSONBytes,
                jsonContinuation: pair.continuation
            )
            self.start(urlRequest, delegate: delegate)
            pair.continuation.onTermination = { @Sendable [weak delegate] _ in
                delegate?.cancelFromConsumer()
            }
            return pair.stream
        }
        var value: Data?
        for try await item in stream {
            guard value == nil else {
                throw transportFailure(
                    "cloud_transport.response_invalid",
                    "cloud JSON transport emitted more than one response"
                )
            }
            value = item
        }
        guard let value else {
            throw transportFailure("cloud_transport.response_invalid", "cloud JSON response was empty")
        }
        return value
    }

    private func validateLimits() throws {
        guard maximumJSONBytes > 0, maximumErrorBytes > 0 else {
            throw transportFailure("cloud_transport.limits_invalid", "cloud response limits are invalid")
        }
    }

    private func validateBeforeTask(
        _ request: AuthorizedCloudHTTPRequest
    ) async throws -> CredentialUseLease {
        let purpose: CredentialUsePurpose
        switch request.authorization {
        case let .generation(seal):
            guard request.wire.dataProvenance == .generation,
                  !seal.generationAuthorizationID.isEmpty,
                  isLowercaseSHA256(seal.generationAuthorizationDigest),
                  isLowercaseSHA256(seal.disclosureDigest)
            else {
                throw transportFailure(
                    "cloud_transport.authorization_invalid",
                    "generation transport authorization is invalid"
                )
            }
            purpose = .preparation
        case let .discovery(seal):
            guard seal.requestClass == .discovery,
                  request.wire.dataProvenance == .noUserData(
                      presetEncoderID: seal.presetEncoderID,
                      requestClass: seal.requestClass
                  )
            else {
                throw transportFailure(
                    "cloud_transport.authorization_invalid",
                    "discovery transport authorization is invalid"
                )
            }
            purpose = .validation
        case let .validation(seal):
            guard seal.requestClass == .accountValidation || seal.requestClass == .modelValidation,
                  request.wire.dataProvenance == .noUserData(
                      presetEncoderID: seal.presetEncoderID,
                      requestClass: seal.requestClass
                  )
            else {
                throw transportFailure(
                    "cloud_transport.authorization_invalid",
                    "validation transport authorization is invalid"
                )
            }
            purpose = .validation
        }
        guard request.origin.scheme == "https",
              !request.profileID.isEmpty,
              !request.credentialRef.isEmpty,
              request.credentialGeneration > 0,
              (request.retentionApprovalRevision == nil)
                == (request.retentionApprovalDigest == nil),
              request.retentionMode == .statelessRequired
                ? request.retentionApprovalRevision == nil
                : request.retentionApprovalRevision != nil
        else {
            throw transportFailure(
                "cloud_transport.authorization_invalid",
                "transport route identity is invalid"
            )
        }
        do {
            let lease = try await credentialStore.revalidateLease(
                request.credentialUseLeaseID,
                credentialRef: request.credentialRef,
                generation: request.credentialGeneration,
                purpose: purpose
            )
            guard try credentialUseLeaseDigest(lease).hex == request.credentialUseLeaseDigest else {
                throw transportFailure(
                    "cloud_transport.authorization_invalid",
                    "credential lease digest no longer matches the request"
                )
            }
            return lease
        } catch let failure as LLMFailure {
            throw failure
        } catch let failure as CredentialFailure {
            throw transportFailure(failure.code, failure.message)
        } catch {
            throw transportFailure(
                "cloud_transport.authorization_invalid",
                "credential lease could not be revalidated"
            )
        }
    }

    private func withCredential<Result: Sendable>(
        request: AuthorizedCloudHTTPRequest,
        lease: CredentialUseLease,
        operation: @Sendable (URLRequest) throws -> Result
    ) async throws -> Result {
        do {
            return try await credentialStore.withCredential(
                for: request.credentialUseLeaseID
            ) { secret in
                guard lease.leaseID == request.credentialUseLeaseID else {
                    throw transportFailure(
                        "cloud_transport.authorization_invalid",
                        "credential lease changed before task creation"
                    )
                }
                let urlRequest = try self.makeURLRequest(request, secret: secret)
                return try operation(urlRequest)
            }
        } catch let failure as LLMFailure {
            throw failure
        } catch let failure as CredentialFailure {
            throw transportFailure(failure.code, failure.message)
        } catch {
            throw transportFailure(
                "cloud_transport.task_creation_failed",
                "cloud request task could not be created",
                retryable: true,
                recoveryAction: .retry
            )
        }
    }

    private func start(
        _ request: URLRequest,
        delegate: CloudURLSessionResponseDelegate
    ) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: queue
        )
        let task = session.dataTask(with: request)
        delegate.attach(session: session, task: task)
        task.resume()
    }

    private func makeURLRequest(
        _ request: AuthorizedCloudHTTPRequest,
        secret: SecretBytes
    ) throws -> URLRequest {
        try CloudTransportPolicy.validateWirePath(request.wire.path)
        guard var components = URLComponents(
            url: request.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw transportFailure("cloud_transport.url_invalid", "provider request URL is invalid")
        }
        let basePath = CloudTransportPolicy.normalizedBasePath(components.path)
        let wirePath = request.wire.path == "/" ? "" : request.wire.path
        components.path = basePath + wirePath
        components.queryItems = request.wire.queryItems.isEmpty ? nil : request.wire.queryItems
        guard let url = components.url else {
            throw transportFailure("cloud_transport.url_invalid", "provider request URL is invalid")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.wire.method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpBody = request.wire.body
        for (name, value) in request.wire.headers {
            let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !transportControlledHeaders.contains(lower),
                  !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n")
            else {
                throw transportFailure(
                    "cloud_transport.header_forbidden",
                    "adapter request contained a transport-controlled header"
                )
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        var secretData = secret.dataCopyForVault()
        defer { zero(&secretData) }
        guard let value = String(data: secretData, encoding: .utf8),
              !value.isEmpty,
              !value.contains("\r"),
              !value.contains("\n")
        else {
            throw transportFailure("credential.invalid_format", "credential is not a valid header value")
        }
        switch request.authentication {
        case .bearerAuthorization:
            urlRequest.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        case .xAPIKeyHeader:
            urlRequest.setValue(value, forHTTPHeaderField: "x-api-key")
        case .googleAPIKeyHeader:
            urlRequest.setValue(value, forHTTPHeaderField: "x-goog-api-key")
        }
        return urlRequest
    }
}

private final class CloudURLSessionResponseDelegate: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private enum Mode {
        case sse(AsyncThrowingStream<SSEEvent, Error>.Continuation)
        case json(Int, AsyncThrowingStream<Data, Error>.Continuation)
    }

    private let lock = NSLock()
    private let request: AuthorizedCloudHTTPRequest
    private let policy: CloudTransportPolicy
    private let maximumErrorBytes: Int
    private let clock: @Sendable () -> Date
    private let mode: Mode
    private var parser = SSEEventParser()
    private var response: HTTPURLResponse?
    private var responseData = Data()
    private var responseOverflow = false
    private var redirectCount = 0
    private var terminal = false
    private weak var task: URLSessionTask?
    private var session: URLSession?

    init(
        request: AuthorizedCloudHTTPRequest,
        policy: CloudTransportPolicy,
        maximumErrorBytes: Int,
        clock: @escaping @Sendable () -> Date,
        sseContinuation: AsyncThrowingStream<SSEEvent, Error>.Continuation
    ) {
        self.request = request
        self.policy = policy
        self.maximumErrorBytes = maximumErrorBytes
        self.clock = clock
        mode = .sse(sseContinuation)
    }

    init(
        request: AuthorizedCloudHTTPRequest,
        policy: CloudTransportPolicy,
        maximumErrorBytes: Int,
        clock: @escaping @Sendable () -> Date,
        maximumJSONBytes: Int,
        jsonContinuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        self.request = request
        self.policy = policy
        self.maximumErrorBytes = maximumErrorBytes
        self.clock = clock
        mode = .json(maximumJSONBytes, jsonContinuation)
    }

    func attach(session: URLSession, task: URLSessionTask) {
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
    }

    func cancelFromConsumer() {
        lock.lock()
        let task = terminal ? nil : task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(transportFailure("cloud_transport.response_invalid", "provider response was not HTTP"))
            completionHandler(.cancel)
            return
        }
        if (200...299).contains(http.statusCode), case .sse = mode {
            let contentType = http.value(forHTTPHeaderField: "content-type")?
                .lowercased()
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard contentType == "text/event-stream" else {
                finish(transportFailure(
                    "cloud_transport.content_type_invalid",
                    "provider streaming response was not an SSE stream"
                ))
                completionHandler(.cancel)
                return
            }
        }
        lock.lock()
        self.response = http
        let isTerminal = terminal
        lock.unlock()
        completionHandler(isTerminal ? .cancel : .allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard !terminal, let response else { lock.unlock(); return }
        let isSuccess = (200...299).contains(response.statusCode)
        if !isSuccess {
            appendBounded(data, maximum: maximumErrorBytes)
            lock.unlock()
            return
        }
        switch mode {
        case .sse:
            lock.unlock()
            do { try emit(parserEvents: appendSSE(data)) } catch { finish(error) }
        case let .json(maximum, _):
            appendBounded(data, maximum: maximum)
            let overflow = responseOverflow
            lock.unlock()
            if overflow {
                finish(transportFailure(
                    "cloud_transport.response_too_large",
                    "cloud JSON response exceeded its limit"
                ))
                dataTask.cancel()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.lock()
        redirectCount += 1
        let count = redirectCount
        let isTerminal = terminal
        lock.unlock()
        guard !isTerminal, let url = newRequest.url else {
            completionHandler(nil)
            return
        }
        do {
            try policy.validateRedirect(
                url,
                expectedOrigin: request.origin,
                baseURL: request.baseURL,
                redirectCount: count
            )
        } catch {
            finish(error)
            completionHandler(nil)
            return
        }
        Task { [policy, request] in
            do {
                try await policy.preflight(
                    baseURL: request.baseURL,
                    expectedOrigin: request.origin
                )
                completionHandler(newRequest)
            } catch {
                self.finish(error)
                completionHandler(nil)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        let response = response
        let data = responseData
        lock.unlock()
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(CancellationError())
            } else {
                finish(transportFailure(
                    "cloud_transport.network_failed",
                    "provider network request failed",
                    retryable: true,
                    recoveryAction: .retry,
                    redactedDiagnostics: [
                        "provider_semantic_id": request.semanticAdapterID,
                    ]
                ))
            }
            return
        }
        guard let response else {
            finish(transportFailure("cloud_transport.response_invalid", "provider response was missing"))
            return
        }
        guard (200...299).contains(response.statusCode) else {
            finish(httpFailure(
                response: response,
                body: data,
                providerSemanticID: request.semanticAdapterID,
                clock: clock
            ))
            return
        }
        switch mode {
        case .sse:
            do {
                try emit(parserEvents: finishSSE())
                finish(nil)
            } catch {
                finish(error)
            }
        case let .json(_, continuation):
            let yielded = continuation.yield(data)
            if case .dropped = yielded {
                finish(transportFailure(
                    "cloud_transport.consumer_backpressure",
                    "cloud JSON consumer did not accept its response"
                ))
            } else {
                finish(nil)
            }
        }
    }

    private func appendBounded(_ data: Data, maximum: Int) {
        guard !responseOverflow else { return }
        guard data.count <= maximum - responseData.count else {
            let remaining = max(0, maximum - responseData.count)
            if remaining > 0 { responseData.append(data.prefix(remaining)) }
            responseOverflow = true
            return
        }
        responseData.append(data)
    }

    private func appendSSE(_ data: Data) throws -> [SSEEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return [] }
        return try parser.append(data)
    }

    private func finishSSE() throws -> [SSEEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return [] }
        return try parser.finish()
    }

    private func emit(parserEvents: [SSEEvent]) throws {
        guard case let .sse(continuation) = mode else { return }
        for event in parserEvents {
            switch continuation.yield(event) {
            case .enqueued:
                continue
            case .dropped:
                throw transportFailure(
                    "cloud_transport.consumer_backpressure",
                    "cloud SSE consumer exceeded its bounded buffer"
                )
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw transportFailure(
                    "cloud_transport.consumer_backpressure",
                    "cloud SSE consumer state was unknown"
                )
            }
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        let mode = mode
        let session = session
        self.session = nil
        task = nil
        lock.unlock()
        switch mode {
        case let .sse(continuation): continuation.finish(throwing: error)
        case let .json(_, continuation): continuation.finish(throwing: error)
        }
        session?.finishTasksAndInvalidate()
    }
}

private let transportControlledHeaders: Set<String> = [
    "authorization", "proxy-authorization", "x-api-key", "x-goog-api-key",
    "cookie", "host", "content-length", "connection",
]

private func httpFailure(
    response: HTTPURLResponse,
    body: Data,
    providerSemanticID: String,
    clock: @Sendable () -> Date
) -> LLMFailure {
    let status = response.statusCode
    var diagnostics: [String: String] = [
        "provider_semantic_id": providerSemanticID,
        "status_class": "\(status / 100)xx",
    ]
    if let requestID = safeRequestID(response: response, body: body) {
        diagnostics["request_id"] = requestID
    }
    if let seconds = retryAfterSeconds(response: response, now: clock()) {
        diagnostics["retry_after_seconds"] = String(seconds)
    }
    switch status {
    case 401:
        return transportFailure(
            "cloud_transport.unauthorized",
            "provider rejected the credential",
            redactedDiagnostics: diagnostics
        )
    case 403:
        return transportFailure(
            "cloud_transport.forbidden",
            "provider denied this request",
            redactedDiagnostics: diagnostics
        )
    case 404:
        return transportFailure(
            "cloud_transport.model_missing",
            "provider model or endpoint was not found",
            redactedDiagnostics: diagnostics
        )
    case 429:
        return transportFailure(
            "cloud_transport.rate_limited",
            "provider rate limit was reached",
            retryable: true,
            recoveryAction: .retry,
            redactedDiagnostics: diagnostics
        )
    case 500...599:
        return transportFailure(
            "cloud_transport.provider_unavailable",
            "provider is temporarily unavailable",
            retryable: true,
            recoveryAction: .retry,
            redactedDiagnostics: diagnostics
        )
    default:
        return transportFailure(
            "cloud_transport.request_rejected",
            "provider rejected the request",
            redactedDiagnostics: diagnostics
        )
    }
}

private func safeRequestID(response: HTTPURLResponse, body: Data) -> String? {
    let header = response.value(forHTTPHeaderField: "x-request-id")
        ?? response.value(forHTTPHeaderField: "request-id")
    if let header, validRequestID(header) { return header }
    guard body.count <= 16 * 1_024,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return nil }
    let candidate = object["request_id"] as? String
        ?? (object["error"] as? [String: Any])?["request_id"] as? String
    guard let candidate, validRequestID(candidate) else { return nil }
    return candidate
}

private func validRequestID(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else { return false }
    return value.utf8.allSatisfy {
        (48...57).contains($0)
            || (65...90).contains($0)
            || (97...122).contains($0)
            || [45, 46, 47, 58, 95].contains($0)
    }
}

private func retryAfterSeconds(response: HTTPURLResponse, now: Date) -> UInt64? {
    guard let value = response.value(forHTTPHeaderField: "retry-after")?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else { return nil }
    if value.allSatisfy(\.isNumber), let seconds = UInt64(value) { return seconds }
    for format in [
        "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'",
        "EEEE',' dd-MMM-yy HH':'mm':'ss 'GMT'",
        "EEE MMM d HH':'mm':'ss yyyy",
    ] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        if let date = formatter.date(from: value) {
            return UInt64(max(0, date.timeIntervalSince(now)).rounded(.up))
        }
    }
    return nil
}

private func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
    }
}

private func zero(_ data: inout Data) {
    _ = data.withUnsafeMutableBytes { bytes in
        bytes.initializeMemory(as: UInt8.self, repeating: 0)
    }
    data.removeAll(keepingCapacity: false)
}
