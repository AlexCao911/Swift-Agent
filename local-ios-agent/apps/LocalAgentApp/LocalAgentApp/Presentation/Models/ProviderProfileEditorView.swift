import CryptoKit
import Darwin
import Foundation
import LocalAgentLLMCloud
import Observation
import SafariServices
import SwiftUI
import UIKit

@MainActor
@Observable
final class ProviderProfileEditorViewModel {
    var presetID: ProviderPresetID = .openAI
    var displayName = "OpenAI"
    var baseURL = "https://api.openai.com/v1"
    var apiKey = ""
    var credentialMode: ProviderCredentialMode = .apiKey
    var retentionMode: ProviderRetentionMode = .statelessRequired
    var providerProjectID = ""
    private(set) var hasStoredCredential = false
    private(set) var errorMessage: String?
    private(set) var didSave = false

    private let client: any ModelCenterClient
    private var profileID: String?
    private var replacingRevision: UInt64?
    private var pendingOAuthSecret: SecretBytes?
    private var oauthLoginTask: Task<Void, Never>?

    var hasPendingOAuthCredential: Bool {
        pendingOAuthSecret != nil
    }

    init(client: any ModelCenterClient) {
        self.client = client
    }

    func load(profileID: String, revision: UInt64) async {
        do {
            let snapshot = try await client.snapshot()
            guard let profile = snapshot.cloudProviders.first(where: {
                $0.profileID == profileID && $0.revision == revision
            }) else {
                errorMessage = "Provider Profile revision is unavailable."
                return
            }
            self.profileID = profile.profileID
            replacingRevision = profile.revision
            presetID = profile.presetID
            displayName = profile.displayName
            baseURL = profile.baseURL.absoluteString
            hasStoredCredential = profile.hasStoredCredential
            retentionMode = profile.retentionMode
            credentialMode = profile.credentialMode
            providerProjectID = profile.providerProjectID ?? ""
            apiKey = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectPreset(_ id: ProviderPresetID) {
        guard let preset = ProviderPreset.shipped.first(where: { $0.id == id }) else {
            return
        }
        presetID = id
        displayName = preset.displayName
        baseURL = preset.defaultBaseURL.absoluteString
        if !availableCredentialModes.contains(credentialMode) {
            credentialMode = availableCredentialModes.first ?? .apiKey
        }
        if id != .antigravity {
            providerProjectID = ""
        }
    }

    var availableCredentialModes: [ProviderCredentialMode] {
        guard let rawType = OpenMinisProviderConfigurationAdapter
            .rawProviderType(for: presetID)
        else {
            return [.apiKey]
        }
        let modes = ProviderProductCompatibility.mapping(
            rawProviderType: rawType
        ).credentialModes
        return [.apiKey, .oauth].filter(modes.contains)
    }

    func save() async {
        guard let url = URL(string: baseURL),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else {
            errorMessage = "Base URL must be an exact HTTPS URL."
            return
        }
        let secret = pendingOAuthSecret
            ?? (apiKey.isEmpty ? nil : SecretBytes(utf8: apiKey))
        let persistsCredential = secret != nil
        defer {
            apiKey = ""
            pendingOAuthSecret = nil
        }
        do {
            try await client.publishProviderProfile(ProviderProfileProductDraft(
                profileID: profileID,
                replacingRevision: replacingRevision,
                presetID: presetID,
                displayName: displayName,
                baseURL: url,
                retentionMode: retentionMode,
                credentialMode: credentialMode,
                providerProjectID: presetID == .antigravity
                    ? providerProjectID
                    : nil,
                initialSecret: secret
            ))
            if persistsCredential {
                hasStoredCredential = true
            }
            didSave = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loginWithOAuth() async {
        do {
            pendingOAuthSecret = try await client.authenticateProviderOAuth(
                presetID: presetID
            )
            credentialMode = .oauth
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginOAuthLogin() {
        oauthLoginTask?.cancel()
        oauthLoginTask = Task { [weak self] in
            await self?.loginWithOAuth()
            self?.oauthLoginTask = nil
        }
    }

    func cancelOAuthLogin() {
        oauthLoginTask?.cancel()
        oauthLoginTask = nil
    }

    func refreshOAuth() async {
        guard let profileID, let replacingRevision else {
            errorMessage = "Save this provider before refreshing OAuth."
            return
        }
        do {
            try await client.refreshProviderOAuth(
                profileID: profileID,
                profileRevision: replacingRevision
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logoutOAuth() async {
        guard let profileID else {
            pendingOAuthSecret = nil
            hasStoredCredential = false
            return
        }
        do {
            try await client.logoutProviderOAuth(
                profileID: profileID,
                profileRevision: replacingRevision ?? 1
            )
            pendingOAuthSecret = nil
            hasStoredCredential = false
            didSave = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ProviderProfileEditorView: View {
    @Bindable var viewModel: ProviderProfileEditorViewModel
    let existingProfile: CloudProviderProductState?
    let onSaved: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: presetBinding) {
                    ForEach(ProviderPreset.shipped, id: \.id) { preset in
                        Text(preset.displayName).tag(preset.id)
                    }
                }
                TextField("Display name", text: $viewModel.displayName)
                TextField("HTTPS Base URL", text: $viewModel.baseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                if viewModel.presetID == .antigravity {
                    TextField(
                        "Cloud Code project ID",
                        text: $viewModel.providerProjectID
                    )
                    .textInputAutocapitalization(.never)
                }
                Picker("Credential", selection: $viewModel.credentialMode) {
                    ForEach(viewModel.availableCredentialModes, id: \.rawValue) {
                        Text($0 == .oauth ? "OAuth Token" : "API Key").tag($0)
                    }
                }
                if viewModel.credentialMode == .oauth {
                    Button(
                        viewModel.hasStoredCredential
                            ? "Sign in again"
                            : "Sign in with OAuth"
                    ) {
                        viewModel.beginOAuthLogin()
                    }
                    if existingProfile != nil && viewModel.hasStoredCredential {
                        Button("Refresh OAuth credential") {
                            Task { await viewModel.refreshOAuth() }
                        }
                        Button("Sign out", role: .destructive) {
                            Task {
                                await viewModel.logoutOAuth()
                                if viewModel.didSave { onSaved() }
                            }
                        }
                    }
                } else {
                    SecureField(credentialPlaceholder, text: $viewModel.apiKey)
                }
                Picker("Retention", selection: $viewModel.retentionMode) {
                    Text("Stateless required")
                        .tag(ProviderRetentionMode.statelessRequired)
                    Text("Provider state approved")
                        .tag(ProviderRetentionMode.providerStateApproved)
                }
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle(existingProfile == nil ? "Add Provider" : "Edit Provider")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.save()
                            if viewModel.didSave { onSaved() }
                        }
                    }
                }
            }
            .task {
                if let existingProfile {
                    await viewModel.load(
                        profileID: existingProfile.profileID,
                        revision: existingProfile.revision
                    )
                }
            }
            .onDisappear { viewModel.cancelOAuthLogin() }
        }
    }

    private var presetBinding: Binding<ProviderPresetID> {
        Binding(
            get: { viewModel.presetID },
            set: { viewModel.selectPreset($0) }
        )
    }

    private var credentialPlaceholder: String {
        let kind = viewModel.credentialMode == .oauth
            ? "OAuth token"
            : "API key"
        return viewModel.hasStoredCredential
            ? "Replace stored \(kind) (optional)"
            : kind
    }
}

@MainActor
enum ProviderOAuthBrowserSession {
    static func authenticate(
        profile: ProviderOAuthProfile,
        client: OAuthHTTPClient
    ) async throws -> SecretBytes {
        let credential: OAuthTokenCredential
        switch profile.flow {
        case .deviceCode:
            credential = try await authenticateDevice(
                profile: profile,
                client: client
            )
        case .authorizationCodePKCE:
            credential = try await authenticateAuthorizationCode(
                profile: profile,
                client: client
            )
        }
        return try credential.secureSecret()
    }

    private static func authenticateDevice(
        profile: ProviderOAuthProfile,
        client: OAuthHTTPClient
    ) async throws -> OAuthTokenCredential {
        guard let path = profile.deviceAuthorizationPath else {
            throw ProviderOAuthBrowserFailure(
                "The device authorization endpoint is unavailable."
            )
        }
        let authorization = try await client.requestDeviceAuthorization(
            profile: profile.tokenEndpoint,
            path: path,
            clientID: profile.clientID
        )
        let cancellation = OAuthBrowserCancellation()
        let browser = try presentSafari(authorization.browserURL) {
            cancellation.cancel()
        }
        defer { browser.dismiss(animated: true) }
        let deadline = Date().addingTimeInterval(authorization.expiresIn)
        var interval = authorization.pollingInterval
        while Date() < deadline {
            try cancellation.check()
            try await Task.sleep(for: .seconds(interval))
            try cancellation.check()
            do {
                return try await client.exchangeDeviceCode(
                    profile: profile.tokenEndpoint,
                    path: profile.tokenPath,
                    clientID: profile.clientID,
                    deviceCode: authorization.deviceCode
                )
            } catch let failure as OAuthHTTPFailure
                where failure.code == "oauth.authorization_pending" {
                continue
            } catch let failure as OAuthHTTPFailure
                where failure.code == "oauth.slow_down" {
                interval += 5
            }
        }
        throw ProviderOAuthBrowserFailure(
            "The OAuth device authorization expired."
        )
    }

    private static func authenticateAuthorizationCode(
        profile: ProviderOAuthProfile,
        client: OAuthHTTPClient
    ) async throws -> OAuthTokenCredential {
        let state = UUID().uuidString.lowercased()
        let verifier = (
            UUID().uuidString + UUID().uuidString
        ).replacingOccurrences(of: "-", with: "")
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let preparation = try await client.prepareAuthorization(
            profile: profile,
            state: state,
            codeChallenge: challenge,
            nonce: profile.presetID == .xAI
                ? UUID().uuidString.lowercased()
                : nil
        )
        guard let redirect = profile.redirectURI,
              redirect.scheme?.lowercased() == "http",
              ["localhost", "127.0.0.1"].contains(
                  redirect.host?.lowercased() ?? ""
              ),
              let port = redirect.port,
              let callbackPort = UInt16(exactly: port)
        else {
            throw ProviderOAuthBrowserFailure(
                "The OAuth callback must be an exact loopback HTTP URL."
            )
        }
        let server = OAuthCallbackServer(
            port: callbackPort,
            callbackPath: redirect.path,
            trustedOrigin: originString(for: preparation.authorizationURL)
        )
        try server.start()
        defer { server.stop() }
        let browser = try presentSafari(preparation.authorizationURL) {
            server.stop()
        }
        defer { browser.dismiss(animated: true) }
        let callback = try await server.waitForCallback(timeout: 300)
        guard callback.state == state else {
            throw ProviderOAuthBrowserFailure(
                "The OAuth callback did not match this sign-in."
            )
        }
        return try await client.exchangeAuthorizationCode(
            preparation: preparation,
            code: callback.code,
            codeVerifier: verifier
        )
    }

    private static func originString(for url: URL) -> String? {
        guard let scheme = url.scheme,
              let host = url.host
        else { return nil }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private static func presentSafari(
        _ url: URL,
        onDismiss: @escaping @MainActor () -> Void = {}
    ) throws -> OAuthSafariBrowserSession {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        else {
            throw ProviderOAuthBrowserFailure(
                "The OAuth browser could not be presented."
            )
        }
        var presenter = root
        while let next = presenter.presentedViewController {
            presenter = next
        }
        let browser = OAuthSafariBrowserSession(url: url, onDismiss: onDismiss)
        presenter.present(browser.controller, animated: true)
        return browser
    }
}

struct OAuthCallbackResult: Equatable, Sendable {
    let code: String
    let state: String?
}

@MainActor
private final class OAuthSafariBrowserSession: NSObject, @preconcurrency SFSafariViewControllerDelegate {
    let controller: SFSafariViewController
    private var onDismiss: (@MainActor () -> Void)?

    init(url: URL, onDismiss: @escaping @MainActor () -> Void) {
        controller = SFSafariViewController(url: url)
        self.onDismiss = onDismiss
        super.init()
        controller.delegate = self
    }

    func dismiss(animated: Bool) {
        onDismiss = nil
        controller.dismiss(animated: animated)
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        let action = onDismiss
        onDismiss = nil
        action?()
    }
}

private final class OAuthBrowserCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }

    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

final class OAuthCallbackServer: @unchecked Sendable {
    private let requestedPort: UInt16
    private let callbackPath: String
    private let queue = DispatchQueue(label: "localagent.oauth.callback")
    private let lock = NSLock()
    private var listenSocket: Int32 = -1
    private var continuation: CheckedContinuation<OAuthCallbackResult, Error>?
    private var bufferedResult: Result<OAuthCallbackResult, Error>?
    private var stopped = true
    private var actualPort: UInt16?
    private let trustedOrigin: String?

    init(
        port: UInt16,
        callbackPath: String,
        trustedOrigin: String? = nil
    ) {
        requestedPort = port
        self.callbackPath = callbackPath.isEmpty ? "/" : callbackPath
        self.trustedOrigin = trustedOrigin
    }

    var boundPort: UInt16? {
        lock.withLock { actualPort }
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ProviderOAuthBrowserFailure(
                "The OAuth callback socket could not be created."
            )
        }
        var reuse: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    fd,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw ProviderOAuthBrowserFailure(
                "The OAuth callback port is unavailable."
            )
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw ProviderOAuthBrowserFailure(
                "The OAuth callback port could not be resolved."
            )
        }
        lock.withLock {
            listenSocket = fd
            actualPort = UInt16(bigEndian: bound.sin_port)
            bufferedResult = nil
            stopped = false
        }
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func waitForCallback(
        timeout: TimeInterval
    ) async throws -> OAuthCallbackResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { value in
                let buffered = lock.withLock { () -> Result<OAuthCallbackResult, Error>? in
                    if let bufferedResult {
                        self.bufferedResult = nil
                        return bufferedResult
                    }
                    guard !stopped, continuation == nil else { return nil }
                    continuation = value
                    return nil
                }
                if let buffered {
                    value.resume(with: buffered)
                    return
                }
                let acceptsWait = lock.withLock { continuation != nil }
                guard acceptsWait else {
                    value.resume(throwing: ProviderOAuthBrowserFailure(
                        "The OAuth callback listener is unavailable."
                    ))
                    return
                }
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(ProviderOAuthBrowserFailure(
                        "OAuth callback timed out."
                    )))
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func stop() {
        finish(.failure(ProviderOAuthBrowserFailure(
            "OAuth sign-in was cancelled."
        )))
    }

    private func acceptLoop() {
        while true {
            let serverFD = lock.withLock { stopped ? -1 : listenSocket }
            guard serverFD >= 0 else { return }
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else { return }
            handleConnection(clientFD)
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0,
              let request = String(
                  bytes: bytes[0..<count],
                  encoding: .utf8
              ),
              let firstLine = request.components(
                  separatedBy: "\r\n"
              ).first
        else { return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(fd, status: "405 Method Not Allowed", html: "")
            return
        }
        let target = String(parts[1])
        guard let components = URLComponents(
            string: "http://127.0.0.1\(target)"
        ), components.path == callbackPath else {
            send(fd, status: "404 Not Found", html: "")
            return
        }
        if parts[0] == "OPTIONS" {
            let origin = request.components(separatedBy: "\r\n").dropFirst()
                .first { $0.lowercased().hasPrefix("origin:") }
                .map { $0.dropFirst("origin:".count).trimmingCharacters(in: .whitespaces) }
            guard let trustedOrigin, origin == trustedOrigin else {
                send(fd, status: "403 Forbidden", html: "")
                return
            }
            send(
                fd,
                status: "204 No Content",
                html: "",
                headers: [
                    "Access-Control-Allow-Origin: \(trustedOrigin)",
                    "Access-Control-Allow-Methods: GET, OPTIONS",
                ]
            )
            return
        }
        guard parts[0] == "GET" else {
            send(fd, status: "405 Method Not Allowed", html: "")
            return
        }
        let query = components.queryItems ?? []
        let codes = query.filter { $0.name == "code" }.map { $0.value ?? "" }
        let states = query.filter { $0.name == "state" }.map { $0.value ?? "" }
        guard codes.count == 1,
              states.count <= 1,
              let code = codes.first,
              !code.isEmpty else {
            send(
                fd,
                status: "400 Bad Request",
                html: "<h1>Authorization failed</h1>"
            )
            finish(.failure(ProviderOAuthBrowserFailure(
                "The OAuth provider did not return an authorization code."
            )))
            return
        }
        send(
            fd,
            status: "200 OK",
            html: "<h1>Authorization successful</h1><p>You can return to LocalAgent.</p>"
        )
        finish(.success(OAuthCallbackResult(
            code: code,
            state: states.first
        )))
    }

    private func send(
        _ fd: Int32,
        status: String,
        html: String,
        headers: [String] = []
    ) {
        let body = """
        <!doctype html><meta name="viewport" content="width=device-width">
        \(html)
        """
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        \(headers.joined(separator: "\r\n"))\(headers.isEmpty ? "" : "\r\n")
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        response.withCString { pointer in
            _ = Darwin.write(fd, pointer, strlen(pointer))
        }
    }

    private func finish(
        _ result: Result<OAuthCallbackResult, Error>
    ) {
        let output: (
            CheckedContinuation<OAuthCallbackResult, Error>?,
            Int32
        ) = lock.withLock {
            guard !stopped else { return (nil, -1) }
            stopped = true
            let value = continuation
            continuation = nil
            if value == nil { bufferedResult = result }
            let fd = listenSocket
            listenSocket = -1
            actualPort = nil
            return (value, fd)
        }
        if output.1 >= 0 { close(output.1) }
        output.0?.resume(with: result)
    }
}

private struct ProviderOAuthBrowserFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
