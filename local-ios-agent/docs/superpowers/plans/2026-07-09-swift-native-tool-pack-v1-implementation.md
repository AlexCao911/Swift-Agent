# Swift Native Tool Pack v1.5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the first Swift native tool pack that makes existing attachments, web reading, OCR, reminders, and calendar scheduling usable through the manifest-backed native toolkit.

**Architecture:** Keep the implementation inside `LocalNativeToolkit`, using existing `NativeTool`, `NativeToolManifest`, `NativeToolExecutor`, `ToolResultEnvelopeV1`, and facade patterns. Runtime tools are exported to Rust only when they are manifest-backed, available, and not `system_action_adapter`; system input capabilities such as Share/App Intents remain app-owned and non-exported.

**Tech Stack:** Swift 6, Swift Testing, SwiftPM package `local-ios-agent/toolkit`, Foundation, optional Vision/EventKit gates through `canImport`.

---

## Source Spec

Design doc:

`local-ios-agent/docs/superpowers/specs/2026-07-09-swift-native-tool-pack-v1-design.md`

This implementation plan covers the required v1.5 runtime set:

- `attachments.list`
- `web.extract_readable_article`
- `vision.extract_text_from_attachment`
- `reminders.search_reminders`
- `calendar.find_free_time`
- `calendar.create_event_user_confirmed`

It also locks the export rule that system input capabilities are not model-callable runtime tools.

This plan does not implement Share Extension, App Intents, Maps, notifications, PDF extraction, speech, or mail draft creation.

## File Structure

### Modify

- `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolSchemaExport.swift`
  - Reject `NativeToolMode.systemActionAdapter` schemas from Rust export.

- `local-ios-agent/toolkit/Sources/LocalNativeToolkit/MetaTools.swift`
  - Continue deriving `native.list_tools` from exported schemas so system inputs stay hidden.

- `local-ios-agent/toolkit/Sources/LocalNativeToolkit/Attachments/NativeAttachmentByteStore.swift`
  - Add `createdAtMillis` metadata.
  - Add `list()` to the byte-store protocol.
  - Implement file-backed listing.

- `local-ios-agent/toolkit/Sources/LocalNativeToolkit/Attachments/AttachmentTools.swift`
  - Add `AttachmentsListTool`.

- `local-ios-agent/toolkit/Sources/LocalNativeToolkit/WebTools.swift`
  - Add readable article extraction primitives and `WebExtractReadableArticleTool`.

- `local-ios-agent/toolkit/Sources/LocalNativeToolkit/CalendarTools.swift`
  - Add calendar free-time DTOs and `CalendarFindFreeTimeTool`.
  - Add user-confirmed calendar event request tool that returns a pending interaction envelope.

- `local-ios-agent/toolkit/Sources/LocalNativeToolkit/ReminderTools.swift`
  - Add reminder search DTOs and `RemindersSearchRemindersTool`.

- `local-ios-agent/toolkit/Sources/LocalNativeToolkit/EventKit/EventKitCalendarAdapter.swift`
  - Add facade support for event range queries used by free-time search.

- `local-ios-agent/toolkit/Sources/LocalNativeToolkit/EventKit/EventKitReminderAdapter.swift`
  - Add facade support for reminder search.

### Create

- `local-ios-agent/toolkit/Sources/LocalNativeToolkit/Vision/VisionTextRecognitionAdapter.swift`
  - Adapter protocol and optional real Vision implementation for OCR.

- `local-ios-agent/toolkit/Sources/LocalNativeToolkit/Vision/VisionTextTools.swift`
  - `VisionExtractTextFromAttachmentTool`.

- `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeSystemInputExportTests.swift`
  - Export/list-tools tests for system input non-export.

- `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/AttachmentListToolTests.swift`
  - Store listing and `attachments.list` tests.

- `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/WebReadableArticleToolTests.swift`
  - Readability extraction tests.

- `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/VisionTextToolTests.swift`
  - OCR tool tests with fake recognizer.

### Existing Tests To Extend

- `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeCapabilityToolsTests.swift`
  - Add reminders search, free-time, and calendar confirmed-event tests.

### Validation Command

Use SwiftPM for this plan:

```bash
swift test --package-path local-ios-agent/toolkit --filter LocalNativeToolkitTests
```

Expected: all `LocalNativeToolkitTests` pass.

---

## Task 1: Lock System Input Non-Export

**Files:**
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolSchemaExport.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeSystemInputExportTests.swift`

- [ ] **Step 1: Write failing tests for system action adapter export**

Create `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeSystemInputExportTests.swift`:

```swift
import Testing
import LocalAgentBridge
@testable import LocalNativeToolkit

@Suite("System input capability export")
struct NativeSystemInputExportTests {
    @Test
    func systemActionAdapterIsNotExportedAsRuntimeToolSchema() throws {
        let schema = NativeToolSchema(
            name: "share.capture_input",
            description: "Capture shared content.",
            inputSchema: .object(),
            riskLevel: .readOnly,
            permissionScope: nil,
            availability: .available,
            manifest: systemInputManifest(name: "share.capture_input")
        )

        #expect(NativeToolSchemaExport.export(schema) == nil)
    }

    @Test
    func nativeListToolsDoesNotListSystemInputCapabilities() async throws {
        let catalog = try NativeToolCatalog(tools: [
            SystemInputStubTool(name: "share.capture_input"),
            SystemInputStubTool(name: "agent.capture_text"),
            RuntimeStubTool(name: "web.extract_readable_article"),
        ])
        let tool = NativeListToolsTool(catalog: catalog)

        let result = await tool.execute(argumentsJson: "{}")
        let object = try decodedJSONObject(result.structuredJson)
        let payload = try #require(object["result"] as? [String: Any])
        let tools = try #require(payload["tools"] as? [[String: Any]])

        #expect(tools.map { $0["name"] as? String } == ["web.extract_readable_article"])
    }

    private func decodedJSONObject(_ json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct SystemInputStubTool: NativeTool {
    var schema: NativeToolSchema

    init(name: String) {
        self.schema = NativeToolSchema(
            name: name,
            description: "System input",
            inputSchema: .object(),
            riskLevel: .readOnly,
            permissionScope: nil,
            availability: .available,
            manifest: systemInputManifest(name: name)
        )
    }

    func execute(argumentsJson: String) async -> ToolResultDTO {
        stubResult()
    }
}

private struct RuntimeStubTool: NativeTool {
    var schema: NativeToolSchema

    init(name: String) {
        self.schema = NativeToolSchema(
            name: name,
            description: "Runtime tool",
            inputSchema: .object(),
            riskLevel: .readOnly,
            permissionScope: nil,
            availability: .available,
            manifest: runtimeManifest(name: name)
        )
    }

    func execute(argumentsJson: String) async -> ToolResultDTO {
        stubResult()
    }
}

private func systemInputManifest(name: String) -> NativeToolManifest {
    NativeToolManifest(
        manifestId: "native.\(name).v1",
        capabilityId: name,
        title: name,
        description: name,
        mode: .systemActionAdapter,
        permissionScope: nil,
        requiredPrivacyKeys: [],
        requiresForegroundUI: true,
        minimumOS: "iOS 17.0",
        regionPolicy: "available_with_service_fallback",
        fallback: NativeToolFallback(kind: .userMediated, message: "Open the app to capture input."),
        riskLevel: .readOnly,
        approvalPolicy: .never,
        trustLevel: .trustedToolResult,
        retention: .runOnly,
        audit: NativeToolAudit(label: name, resultSummaryPolicy: .metadataOnly)
    )
}

private func runtimeManifest(name: String) -> NativeToolManifest {
    NativeToolManifest(
        manifestId: "native.\(name).v1",
        capabilityId: name,
        title: name,
        description: name,
        mode: .background,
        permissionScope: nil,
        requiredPrivacyKeys: [],
        requiresForegroundUI: false,
        minimumOS: "iOS 17.0",
        regionPolicy: "available_with_service_fallback",
        fallback: NativeToolFallback(kind: .none, message: ""),
        riskLevel: .readOnly,
        approvalPolicy: .never,
        trustLevel: .trustedToolResult,
        retention: .runOnly,
        audit: NativeToolAudit(label: name, resultSummaryPolicy: .metadataOnly)
    )
}

private func stubResult() -> ToolResultDTO {
    ToolResultDTO(
        displayText: "ok",
        modelText: "ok",
        structuredJson: "{}",
        auditText: "ok",
        sensitivity: .public,
        retention: .runOnly,
        isError: false
    )
}
```

- [ ] **Step 2: Run failing export tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter NativeSystemInputExportTests
```

Expected: `systemActionAdapterIsNotExportedAsRuntimeToolSchema` fails because `NativeToolSchemaExport.export(_:)` still exports manifest-backed system action adapter schemas.

- [ ] **Step 3: Implement export guard**

Modify `local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolSchemaExport.swift`:

```swift
public static func export(_ schema: NativeToolSchema) -> ToolSchemaDTO? {
    guard schema.availability == .available,
          let manifest = schema.manifest,
          manifest.mode != .systemActionAdapter
    else {
        return nil
    }
    let effectiveRisk = effectiveRiskLevel(schema.riskLevel, manifest.riskLevel)
    guard let metadataJson = metadataJSON(for: schema) else {
        return nil
    }

    return ToolSchemaDTO(
        name: schema.name,
        description: schema.description,
        parametersJsonSchema: schema.inputSchema.jsonString,
        riskLevel: bridgeRiskLevel(for: effectiveRisk),
        metadataJson: metadataJson
    )
}
```

- [ ] **Step 4: Run export tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter NativeSystemInputExportTests
```

Expected: PASS.

- [ ] **Step 5: Run existing schema export and meta tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter NativeToolSchemaExportTests
swift test --package-path local-ios-agent/toolkit --filter MetaToolsTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/NativeToolSchemaExport.swift local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeSystemInputExportTests.swift
git commit -m "fix: keep system inputs out of runtime tools"
```

---

## Task 2: Add Attachment Listing Store Support

**Files:**
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/Attachments/NativeAttachmentByteStore.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/AttachmentToolTests.swift`

- [ ] **Step 1: Write failing store listing test**

Append to `AttachmentToolTests`:

```swift
@Test
func byteStoreListsMetadataNewestFirstWithoutRawPaths() async throws {
    let directory = temporaryDirectory()
    let store = try FileBackedNativeAttachmentByteStore(directory: directory)

    let first = try await store.put(
        Data("first".utf8),
        filename: "first.txt",
        contentType: "text/plain"
    )
    try await Task.sleep(nanoseconds: 1_000_000)
    let second = try await store.put(
        Data("second".utf8),
        filename: "second.txt",
        contentType: "text/plain"
    )

    let listed = try await store.list()

    #expect(listed.map(\.attachmentId) == [second.attachmentId, first.attachmentId])
    #expect(listed.map(\.filename) == ["second.txt", "first.txt"])
    #expect(String(describing: listed).contains(directory.path) == false)
}
```

- [ ] **Step 2: Run failing attachment tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter AttachmentToolTests/byteStoreListsMetadataNewestFirstWithoutRawPaths
```

Expected: FAIL because `NativeAttachmentByteStore` has no `list()` method and `NativeAttachmentStoredBytes` has no creation timestamp.

- [ ] **Step 3: Extend attachment metadata and protocol**

Modify `NativeAttachmentStoredBytes` in `NativeAttachmentByteStore.swift`:

```swift
public struct NativeAttachmentStoredBytes: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var filename: String
    public var contentType: String
    public var byteCount: Int
    public var createdAtMillis: UInt64

    public init(
        attachmentId: String,
        filename: String,
        contentType: String,
        byteCount: Int,
        createdAtMillis: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.attachmentId = attachmentId
        self.filename = filename
        self.contentType = contentType
        self.byteCount = byteCount
        self.createdAtMillis = createdAtMillis
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentId = "attachment_id"
        case filename
        case contentType = "content_type"
        case byteCount = "byte_count"
        case createdAtMillis = "created_at_millis"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.attachmentId = try container.decode(String.self, forKey: .attachmentId)
        self.filename = try container.decode(String.self, forKey: .filename)
        self.contentType = try container.decode(String.self, forKey: .contentType)
        self.byteCount = try container.decode(Int.self, forKey: .byteCount)
        self.createdAtMillis = try container.decodeIfPresent(UInt64.self, forKey: .createdAtMillis) ?? 0
    }
}
```

Modify `NativeAttachmentByteStore` protocol:

```swift
public protocol NativeAttachmentByteStore: Sendable {
    func put(_ data: Data, filename: String, contentType: String) async throws -> NativeAttachmentStoredBytes
    func describe(attachmentId: String) async throws -> NativeAttachmentStoredBytes
    func read(attachmentId: String, maxBytes: Int) async throws -> Data
    func list() async throws -> [NativeAttachmentStoredBytes]
}
```

- [ ] **Step 4: Implement file-backed list**

Add to `FileBackedNativeAttachmentByteStore`:

```swift
public func list() async throws -> [NativeAttachmentStoredBytes] {
    let urls = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    let metadata = try urls
        .filter { $0.pathExtension == "json" }
        .map { url in
            let data = try Data(contentsOf: url)
            return try decoder.decode(NativeAttachmentStoredBytes.self, from: data)
        }
    return metadata.sorted { lhs, rhs in
        if lhs.createdAtMillis == rhs.createdAtMillis {
            return lhs.filename < rhs.filename
        }
        return lhs.createdAtMillis > rhs.createdAtMillis
    }
}
```

- [ ] **Step 5: Run attachment tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter AttachmentToolTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/Attachments/NativeAttachmentByteStore.swift local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/AttachmentToolTests.swift
git commit -m "feat: list native attachments"
```

---

## Task 3: Add `attachments.list`

**Files:**
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/Attachments/AttachmentTools.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/AttachmentListToolTests.swift`

- [ ] **Step 1: Write failing tool tests**

Create `AttachmentListToolTests.swift`:

```swift
import Foundation
import Testing
@testable import LocalNativeToolkit

@Suite("Attachments list tool")
struct AttachmentListToolTests {
    @Test
    func listAttachmentsReturnsScopedMetadataWithoutRawPaths() async throws {
        let directory = temporaryDirectory()
        let store = try FileBackedNativeAttachmentByteStore(directory: directory)
        let first = try await store.put(Data("one".utf8), filename: "one.txt", contentType: "text/plain")
        try await Task.sleep(nanoseconds: 1_000_000)
        let second = try await store.put(Data("two".utf8), filename: "two.txt", contentType: "text/plain")
        let tool = AttachmentsListTool(store: store)

        let result = await tool.execute(argumentsJson: #"{"conversation_id":"ignored","run_id":"ignored"}"#)
        let object = try decodedJSONObject(result.structuredJson)
        let payload = try #require(object["result"] as? [String: Any])
        let attachments = try #require(payload["attachments"] as? [[String: Any]])
        let contextPolicy = try #require(object["context_policy"] as? [String: Any])

        #expect(result.isError == false)
        #expect(attachments.map { $0["attachment_id"] as? String } == [second.attachmentId, first.attachmentId])
        #expect(attachments[0]["display_name"] as? String == "two.txt")
        #expect(attachments[0]["content_type"] as? String == "text/plain")
        #expect(attachments[0]["access_state"] as? String == "available")
        #expect(contextPolicy["trust_level"] as? String == "trusted_tool_result")
        #expect(result.structuredJson.contains(directory.path) == false)
    }

    @Test
    func listAttachmentsSchemaIsReadOnlyAndManifestBacked() throws {
        let tool = AttachmentsListTool(store: EmptyAttachmentStore())

        #expect(tool.schema.name == "attachments.list")
        #expect(tool.schema.riskLevel == .readOnly)
        #expect(tool.schema.manifest?.manifestId == "native.attachments.list.v1")
        #expect(tool.schema.manifest?.mode == .background)
        #expect(NativeToolSchemaExport.export(tool.schema) != nil)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "attachment-list-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func decodedJSONObject(_ json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct EmptyAttachmentStore: NativeAttachmentByteStore {
    func put(_ data: Data, filename: String, contentType: String) async throws -> NativeAttachmentStoredBytes {
        NativeAttachmentStoredBytes(attachmentId: "att_empty", filename: filename, contentType: contentType, byteCount: data.count)
    }

    func describe(attachmentId: String) async throws -> NativeAttachmentStoredBytes {
        throw NativeAttachmentByteStoreError.notFound
    }

    func read(attachmentId: String, maxBytes: Int) async throws -> Data {
        throw NativeAttachmentByteStoreError.notFound
    }

    func list() async throws -> [NativeAttachmentStoredBytes] {
        []
    }
}
```

- [ ] **Step 2: Run failing tool tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter AttachmentListToolTests
```

Expected: FAIL because `AttachmentsListTool` does not exist.

- [ ] **Step 3: Implement `AttachmentsListTool`**

Append to `AttachmentTools.swift` before `PhotosDescribeAttachmentTool`:

```swift
public struct AttachmentsListTool: NativeTool {
    public let schema: NativeToolSchema
    private let store: any NativeAttachmentByteStore

    public init(store: any NativeAttachmentByteStore) {
        self.store = store
        self.schema = Self.makeSchema()
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        do {
            let attachments = try await store.list()
            return NativeToolResultBuilder.success(
                manifestId: Self.manifest.manifestId,
                toolName: schema.name,
                toolCallId: "unknown",
                displayText: "\(attachments.count) attachments available.",
                modelText: "Available attachments: \(attachments.map(\.filename).joined(separator: ", "))",
                resultKind: "attachments_list",
                resultPayload: [
                    "count": .number(Double(attachments.count)),
                    "attachments": .array(attachments.map(Self.attachmentJSONValue)),
                ],
                sourceKind: "attachment_store",
                sourceId: "current_run",
                displayName: Self.manifest.title,
                attachmentIds: attachments.map(\.attachmentId),
                trustLevel: Self.manifest.trustLevel,
                sensitivity: .private,
                retention: Self.manifest.retention,
                modelTextPolicy: "metadata_only",
                sourceLabel: "Attachments",
                auditSummary: "Listed current-run attachments.",
                auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
            )
        } catch {
            return NativeToolResultBuilder.error(
                manifestId: Self.manifest.manifestId,
                toolName: schema.name,
                toolCallId: "unknown",
                code: "attachments_list_failed",
                displayText: "Unable to list attachments.",
                auditSummary: "Attachment listing failed.",
                sensitivity: .private,
                retention: Self.manifest.retention
            )
        }
    }

    private static var manifest: NativeToolManifest {
        NativeToolManifest(
            manifestId: "native.attachments.list.v1",
            capabilityId: "attachments.list",
            title: "List Attachments",
            description: "List attachments available to the current run.",
            mode: .background,
            permissionScope: nil,
            requiredPrivacyKeys: [],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .none, message: ""),
            riskLevel: .readOnly,
            approvalPolicy: .never,
            trustLevel: .trustedToolResult,
            retention: .runOnly,
            audit: NativeToolAudit(label: "List Attachments", resultSummaryPolicy: .metadataOnly)
        )
    }

    private static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "attachments.list",
            description: manifest.description,
            inputSchema: .object(
                properties: [
                    "conversation_id": .string(),
                    "run_id": .string(),
                    "source_family": .string(),
                ],
                required: []
            ),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    private static func attachmentJSONValue(_ metadata: NativeAttachmentStoredBytes) -> JSONValue {
        .object([
            "attachment_id": .string(metadata.attachmentId),
            "display_name": .string(metadata.filename),
            "content_type": .string(metadata.contentType),
            "source_family": .string(sourceFamily(for: metadata.contentType)),
            "size_bytes": .number(Double(metadata.byteCount)),
            "trust_level": .string(NativeToolTrustLevel.untrustedExternalContent.rawValue),
            "sensitivity": .string("private"),
            "access_state": .string("available"),
        ])
    }

    private static func sourceFamily(for contentType: String) -> String {
        if contentType.hasPrefix("image/") {
            return "photos"
        }
        return "files"
    }
}
```

- [ ] **Step 4: Run attachment list tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter AttachmentListToolTests
```

Expected: PASS.

- [ ] **Step 5: Run full attachment tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter AttachmentToolTests
swift test --package-path local-ios-agent/toolkit --filter AttachmentListToolTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/Attachments/AttachmentTools.swift local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/AttachmentListToolTests.swift
git commit -m "feat: add attachments list tool"
```

---

## Task 4: Add `web.extract_readable_article`

**Files:**
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/WebTools.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/WebReadableArticleToolTests.swift`

- [ ] **Step 1: Write failing readable article tests**

Create `WebReadableArticleToolTests.swift`:

```swift
import Foundation
import Testing
@testable import LocalNativeToolkit

@Suite("Web readable article tool")
struct WebReadableArticleToolTests {
    @Test
    func extractsReadableArticleFromStaticHTMLWithoutJavaScript() async throws {
        let html = """
        <html>
          <head><title>Example Article</title></head>
          <body>
            <nav>Navigation</nav>
            <article>
              <h1>Example Article</h1>
              <p>First useful paragraph.</p>
              <script>window.secret = 'do not run';</script>
              <p>Second useful paragraph.</p>
            </article>
          </body>
        </html>
        """
        let tool = WebExtractReadableArticleTool(fetcher: StaticWebFetcher(
            data: Data(html.utf8),
            mimeType: "text/html"
        ))

        let result = await tool.execute(argumentsJson: #"{"url":"https://example.com/article","max_characters":12000}"#)
        let object = try decodedJSONObject(result.structuredJson)
        let payload = try #require(object["result"] as? [String: Any])
        let provenance = try #require(object["provenance"] as? [String: Any])
        let contextPolicy = try #require(object["context_policy"] as? [String: Any])

        #expect(result.isError == false)
        #expect(payload["title"] as? String == "Example Article")
        #expect((payload["excerpt"] as? String)?.contains("First useful paragraph.") == true)
        #expect((payload["excerpt"] as? String)?.contains("window.secret") == false)
        #expect(provenance["trust_level"] as? String == "untrusted_external_content")
        #expect(contextPolicy["trust_level"] as? String == "untrusted_external_content")
    }

    @Test
    func readableArticlePolicyRejectsHTTP() async throws {
        let tool = WebExtractReadableArticleTool(fetcher: StaticWebFetcher(
            data: Data("ok".utf8),
            mimeType: "text/html"
        ))

        let result = await tool.execute(argumentsJson: #"{"url":"http://example.com"}"#)

        #expect(result.isError)
        #expect(result.structuredJson.contains("web_fetch.scheme_denied"))
    }

    private func decodedJSONObject(_ json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct StaticWebFetcher: WebFetching {
    let data: Data
    let mimeType: String

    func fetch(_ request: URLRequest, policy: WebFetchPolicyV1) async throws -> WebFetchResponse {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mimeType]
        )!
        return WebFetchResponse(data: data, response: response, redirectChain: [])
    }
}
```

- [ ] **Step 2: Run failing readable article tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter WebReadableArticleToolTests
```

Expected: FAIL because `WebExtractReadableArticleTool` does not exist.

- [ ] **Step 3: Add readability extraction helper**

Append to `WebTools.swift`:

```swift
public struct ReadableArticle: Sendable, Equatable {
    public var title: String
    public var excerpt: String
    public var truncated: Bool
}

public enum StaticHTMLReadableArticleExtractor {
    public static func extract(html: String, maxCharacters: Int) -> ReadableArticle {
        let title = firstMatch(
            pattern: #"<title[^>]*>(.*?)</title>"#,
            in: html
        ).map(stripTagsAndCollapseWhitespace) ?? "Untitled Page"
        let article = firstMatch(
            pattern: #"<article[^>]*>(.*?)</article>"#,
            in: html
        ) ?? html
        let withoutScripts = article
            .replacingOccurrences(
                of: #"<script[\s\S]*?</script>"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"<style[\s\S]*?</style>"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        let text = stripTagsAndCollapseWhitespace(withoutScripts)
        let excerpt = String(text.prefix(max(0, maxCharacters)))
        return ReadableArticle(
            title: title,
            excerpt: excerpt,
            truncated: excerpt.count < text.count
        )
    }

    private static func firstMatch(pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[captureRange])
    }

    private static func stripTagsAndCollapseWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"<[^>]+>"#,
                with: " ",
                options: [.regularExpression]
            )
            .replacingOccurrences(
                of: #"&nbsp;"#,
                with: " ",
                options: [.caseInsensitive]
            )
            .replacingOccurrences(
                of: #"&amp;"#,
                with: "&",
                options: [.caseInsensitive]
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: [.regularExpression]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Add `WebExtractReadableArticleTool`**

Append to `WebTools.swift` after `WebFetchURLTextTool`:

```swift
public struct WebExtractReadableArticleTool: NativeTool {
    public let schema: NativeToolSchema
    private let policy: WebFetchPolicyV1
    private let fetcher: any WebFetching

    public init(
        policy: WebFetchPolicyV1 = .default,
        fetcher: any WebFetching = URLSessionWebFetcher()
    ) {
        self.policy = policy
        self.fetcher = fetcher
        self.schema = Self.makeSchema()
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        guard let arguments = Self.decodeArguments(argumentsJson) else {
            return Self.error(code: "web_fetch.invalid_arguments", displayText: "Expected url.")
        }
        var request = URLRequest(url: arguments.url)
        request.timeoutInterval = policy.timeoutSeconds
        request.httpShouldHandleCookies = false
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        switch policy.validate(request) {
        case .allowed:
            break
        case .denied(let code):
            return Self.error(code: code, displayText: "This URL is blocked by the web fetch policy.")
        }

        do {
            let fetched = try await fetcher.fetch(request, policy: policy)
            guard fetched.data.count <= policy.maxResponseBytes else {
                return Self.error(code: "web_fetch.response_too_large", displayText: "The response is too large.")
            }
            if let http = fetched.response as? HTTPURLResponse,
               !policy.allowsMimeType(http.mimeType) {
                return Self.error(code: "web_fetch.mime_denied", displayText: "The response type is not allowed.")
            }
            let html = String(decoding: fetched.data, as: UTF8.self)
            let article = StaticHTMLReadableArticleExtractor.extract(
                html: html,
                maxCharacters: arguments.maxCharacters
            )
            return NativeToolResultBuilder.success(
                manifestId: Self.manifest.manifestId,
                toolName: schema.name,
                toolCallId: "unknown",
                displayText: "Read article: \(article.title)",
                modelText: "External web article from \(arguments.url.absoluteString):\n\(article.excerpt)",
                resultKind: "web_readable_article",
                resultPayload: [
                    "url": .string(arguments.url.absoluteString),
                    "final_url": .string((fetched.response.url ?? arguments.url).absoluteString),
                    "title": .string(article.title),
                    "site_name": .string(arguments.url.host() ?? ""),
                    "excerpt": .string(article.excerpt),
                    "content_truncated": .bool(article.truncated),
                ],
                sourceKind: "web",
                sourceId: arguments.url.absoluteString,
                displayName: article.title,
                attachmentIds: [],
                trustLevel: .untrustedExternalContent,
                sensitivity: .public,
                retention: Self.manifest.retention,
                modelTextPolicy: "summarize_or_quote_only",
                sourceLabel: "Web",
                auditSummary: "Extracted readable article from \(arguments.url.absoluteString).",
                auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
            )
        } catch WebFetchError.policyDenied(let code) {
            return Self.error(code: code, displayText: "A redirect was blocked by the web fetch policy.")
        } catch {
            return Self.error(code: "web_fetch.network_error", displayText: "The URL could not be fetched.")
        }
    }

    private static var manifest: NativeToolManifest {
        NativeToolManifest(
            manifestId: "native.web.extract_readable_article.v1",
            capabilityId: "web.extract_readable_article",
            title: "Read Web Article",
            description: "Extract bounded readable text from a public HTTPS page.",
            mode: .background,
            permissionScope: NativePermissionScope("web.fetch.approved"),
            requiredPrivacyKeys: [],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .unavailable, message: "Use visible browser handoff for pages that require login or JavaScript."),
            riskLevel: .confirm,
            approvalPolicy: .perCall,
            trustLevel: .untrustedExternalContent,
            retention: .runOnly,
            audit: NativeToolAudit(label: "Read Web Article", resultSummaryPolicy: .excerptOnly)
        )
    }

    private static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "web.extract_readable_article",
            description: manifest.description,
            inputSchema: .object(
                properties: [
                    "url": .string(),
                    "max_characters": .string(),
                ],
                required: ["url"]
            ),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    private static func decodeArguments(_ json: String) -> (url: URL, maxCharacters: Int)? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["url"] as? String,
              let url = URL(string: value)
        else {
            return nil
        }
        let maxCharacters = object["max_characters"] as? Int ?? 12_000
        return (url, max(0, min(maxCharacters, 24_000)))
    }

    private static func error(code: String, displayText: String) -> ToolResultDTO {
        NativeToolResultBuilder.error(
            manifestId: manifest.manifestId,
            toolName: "web.extract_readable_article",
            toolCallId: "unknown",
            code: code,
            displayText: displayText,
            auditSummary: "Readable article extraction failed: \(code)"
        )
    }
}
```

- [ ] **Step 5: Run web tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter WebReadableArticleToolTests
swift test --package-path local-ios-agent/toolkit --filter WebToolsTests
swift test --package-path local-ios-agent/toolkit --filter WebFetchPolicyTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/WebTools.swift local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/WebReadableArticleToolTests.swift
git commit -m "feat: add readable web article tool"
```

---

## Task 5: Add `vision.extract_text_from_attachment`

**Files:**
- Create: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/Vision/VisionTextRecognitionAdapter.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/Vision/VisionTextTools.swift`
- Create: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/VisionTextToolTests.swift`

- [ ] **Step 1: Write failing OCR tool tests**

Create `VisionTextToolTests.swift`:

```swift
import Foundation
import Testing
@testable import LocalNativeToolkit

@Suite("Vision text tool")
struct VisionTextToolTests {
    @Test
    func extractTextFromAttachmentUsesRecognizerAndMarksExternalContentUntrusted() async throws {
        let directory = temporaryDirectory()
        let store = try FileBackedNativeAttachmentByteStore(directory: directory)
        let stored = try await store.put(Data([0, 1, 2]), filename: "receipt.png", contentType: "image/png")
        let recognizer = FakeVisionTextRecognizer(text: "Total $12.50", confidenceSummary: "high")
        let tool = VisionExtractTextFromAttachmentTool(store: store, recognizer: recognizer)

        let result = await tool.execute(argumentsJson: #"{"attachment_id":"\#(stored.attachmentId)","max_characters":12000}"#)
        let object = try decodedJSONObject(result.structuredJson)
        let payload = try #require(object["result"] as? [String: Any])
        let provenance = try #require(object["provenance"] as? [String: Any])
        let contextPolicy = try #require(object["context_policy"] as? [String: Any])

        #expect(result.isError == false)
        #expect(payload["text"] as? String == "Total $12.50")
        #expect(payload["attachment_id"] as? String == stored.attachmentId)
        #expect(provenance["trust_level"] as? String == "untrusted_external_content")
        #expect(contextPolicy["trust_level"] as? String == "untrusted_external_content")
    }

    @Test
    func missingAttachmentReturnsRepairablePrivateError() async throws {
        let directory = temporaryDirectory()
        let store = try FileBackedNativeAttachmentByteStore(directory: directory)
        let tool = VisionExtractTextFromAttachmentTool(store: store, recognizer: FakeVisionTextRecognizer(text: "", confidenceSummary: "low"))

        let result = await tool.execute(argumentsJson: #"{"attachment_id":"missing"}"#)

        #expect(result.isError)
        #expect(result.sensitivity == .private)
        #expect(result.structuredJson.contains("attachment_not_found"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "vision-text-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func decodedJSONObject(_ json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct FakeVisionTextRecognizer: VisionTextRecognizing {
    let text: String
    let confidenceSummary: String

    func recognizeText(in data: Data, contentType: String, languageHint: String?) async throws -> VisionTextRecognitionResult {
        VisionTextRecognitionResult(text: text, confidenceSummary: confidenceSummary)
    }
}
```

- [ ] **Step 2: Run failing OCR tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter VisionTextToolTests
```

Expected: FAIL because `VisionTextRecognizing`, `VisionTextRecognitionResult`, and `VisionExtractTextFromAttachmentTool` do not exist.

- [ ] **Step 3: Add recognition adapter protocol**

Create `VisionTextRecognitionAdapter.swift`:

```swift
import Foundation

public struct VisionTextRecognitionResult: Sendable, Equatable {
    public var text: String
    public var confidenceSummary: String

    public init(text: String, confidenceSummary: String) {
        self.text = text
        self.confidenceSummary = confidenceSummary
    }
}

public protocol VisionTextRecognizing: Sendable {
    func recognizeText(
        in data: Data,
        contentType: String,
        languageHint: String?
    ) async throws -> VisionTextRecognitionResult
}

public struct UnavailableVisionTextRecognizer: VisionTextRecognizing {
    public init() {}

    public func recognizeText(
        in data: Data,
        contentType: String,
        languageHint: String?
    ) async throws -> VisionTextRecognitionResult {
        throw VisionTextRecognitionError.unavailable
    }
}

public enum VisionTextRecognitionError: Error, Equatable, Sendable {
    case unavailable
    case noText
}

#if canImport(Vision)
import ImageIO
import Vision

public struct VisionTextRecognitionAdapter: VisionTextRecognizing {
    public init() {}

    public func recognizeText(
        in data: Data,
        contentType: String,
        languageHint: String?
    ) async throws -> VisionTextRecognitionResult {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
        else {
            throw VisionTextRecognitionError.noText
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        if let languageHint, !languageHint.isEmpty {
            request.recognitionLanguages = [languageHint]
        }
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else {
            throw VisionTextRecognitionError.noText
        }
        return VisionTextRecognitionResult(
            text: lines.joined(separator: "\n"),
            confidenceSummary: "medium"
        )
    }
}
#endif
```

- [ ] **Step 4: Add OCR tool**

Create `VisionTextTools.swift`:

```swift
import Foundation
import LocalAgentBridge

public struct VisionExtractTextFromAttachmentTool: NativeTool {
    public let schema: NativeToolSchema
    private let store: any NativeAttachmentByteStore
    private let recognizer: any VisionTextRecognizing

    public init(
        store: any NativeAttachmentByteStore,
        recognizer: any VisionTextRecognizing
    ) {
        self.store = store
        self.recognizer = recognizer
        self.schema = Self.makeSchema()
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        guard let arguments = Self.decodeArguments(argumentsJson) else {
            return Self.error(code: "invalid_arguments", displayText: "Expected attachment_id.")
        }
        do {
            let metadata = try await store.describe(attachmentId: arguments.attachmentId)
            let data = try await store.read(attachmentId: arguments.attachmentId, maxBytes: arguments.maxBytes)
            let recognized = try await recognizer.recognizeText(
                in: data,
                contentType: metadata.contentType,
                languageHint: arguments.languageHint
            )
            let text = String(recognized.text.prefix(arguments.maxCharacters))
            return NativeToolResultBuilder.success(
                manifestId: Self.manifest.manifestId,
                toolName: schema.name,
                toolCallId: "unknown",
                displayText: "Extracted text from \(metadata.filename).",
                modelText: "External OCR text from \(metadata.filename):\n\(text)",
                resultKind: "ocr_text",
                resultPayload: [
                    "attachment_id": .string(metadata.attachmentId),
                    "text": .string(text),
                    "content_truncated": .bool(text.count < recognized.text.count),
                    "confidence_summary": .string(recognized.confidenceSummary),
                ],
                sourceKind: "attachment",
                sourceId: metadata.attachmentId,
                displayName: metadata.filename,
                attachmentIds: [metadata.attachmentId],
                trustLevel: .untrustedExternalContent,
                sensitivity: .private,
                retention: Self.manifest.retention,
                modelTextPolicy: "summarize_or_quote_only",
                sourceLabel: "OCR",
                auditSummary: "Extracted OCR text from attachment \(metadata.attachmentId).",
                auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
            )
        } catch NativeAttachmentByteStoreError.notFound {
            return Self.error(code: "attachment_not_found", displayText: "Attachment was not found.")
        } catch {
            return Self.error(code: "ocr_failed", displayText: "Unable to extract text from this attachment.")
        }
    }

    private static var manifest: NativeToolManifest {
        NativeToolManifest(
            manifestId: "native.vision.extract_text_from_attachment.v1",
            capabilityId: "vision.extract_text_from_attachment",
            title: "Extract Text From Image",
            description: "Extract text from an image or scan attachment.",
            mode: .background,
            permissionScope: nil,
            requiredPrivacyKeys: [],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .userMediated, message: "Reselect the attachment if access expired."),
            riskLevel: .readOnly,
            approvalPolicy: .perCall,
            trustLevel: .untrustedExternalContent,
            retention: .runOnly,
            audit: NativeToolAudit(label: "OCR Attachment", resultSummaryPolicy: .excerptOnly)
        )
    }

    private static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "vision.extract_text_from_attachment",
            description: manifest.description,
            inputSchema: .object(
                properties: [
                    "attachment_id": .string(),
                    "max_characters": .string(),
                    "language_hint": .string(),
                ],
                required: ["attachment_id"]
            ),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    private static func decodeArguments(_ json: String) -> (attachmentId: String, maxCharacters: Int, maxBytes: Int, languageHint: String?)? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attachmentId = object["attachment_id"] as? String
        else {
            return nil
        }
        let maxCharacters = object["max_characters"] as? Int ?? 12_000
        return (
            attachmentId,
            max(0, min(maxCharacters, 24_000)),
            8_000_000,
            object["language_hint"] as? String
        )
    }

    private static func error(code: String, displayText: String) -> ToolResultDTO {
        NativeToolResultBuilder.error(
            manifestId: manifest.manifestId,
            toolName: "vision.extract_text_from_attachment",
            toolCallId: "unknown",
            code: code,
            displayText: displayText,
            auditSummary: "OCR failed: \(code)",
            sensitivity: .private,
            retention: manifest.retention
        )
    }
}
```

- [ ] **Step 5: Run OCR tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter VisionTextToolTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/Vision local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/VisionTextToolTests.swift
git commit -m "feat: add OCR attachment tool"
```

---

## Task 6: Add `reminders.search_reminders`

**Files:**
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/ReminderTools.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/EventKit/EventKitReminderAdapter.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeCapabilityToolsTests.swift`

- [ ] **Step 1: Add failing reminder search test**

Append to `NativeCapabilityToolsTests`:

```swift
@Test
func remindersSearchUsesInjectedFacade() async throws {
    let facade = RecordingRemindersFacade(reminders: [
        NativeReminder(id: "reminder_1", title: "Buy milk", notes: nil, dueDateISO8601: "2026-07-10T09:00:00Z"),
    ])
    let tool = RemindersSearchRemindersTool(reminders: facade)

    let result = await tool.execute(argumentsJson: #"{"query":"milk","include_completed":false,"limit":10}"#)
    let object = try decodedJSONObject(result.structuredJson)
    let payload = try #require(object["result"] as? [String: Any])
    let reminders = try #require(payload["reminders"] as? [[String: Any]])

    #expect(tool.schema.name == "reminders.search_reminders")
    #expect(tool.schema.riskLevel == .readOnly)
    #expect(await facade.searchRequests == [
        NativeReminderSearchRequest(query: "milk", includeCompleted: false, dueFromISO8601: nil, dueToISO8601: nil, limit: 10),
    ])
    #expect(result.isError == false)
    #expect(reminders.map { $0["title"] as? String } == ["Buy milk"])
}
```

Replace `RecordingRemindersFacade` with this version:

```swift
private actor RecordingRemindersFacade: RemindersFacade {
    private let reminder: NativeReminder
    private let searchResults: [NativeReminder]
    private var requests: [NativeReminderCreateRequest] = []
    private var searches: [NativeReminderSearchRequest] = []

    init(reminder: NativeReminder) {
        self.reminder = reminder
        self.searchResults = []
    }

    init(reminders: [NativeReminder]) {
        self.reminder = NativeReminder(id: "created", title: "created", notes: nil, dueDateISO8601: nil)
        self.searchResults = reminders
    }

    var createdRequests: [NativeReminderCreateRequest] {
        requests
    }

    var searchRequests: [NativeReminderSearchRequest] {
        searches
    }

    func createReminder(_ request: NativeReminderCreateRequest) async throws -> NativeReminder {
        requests.append(request)
        return reminder
    }

    func searchReminders(_ request: NativeReminderSearchRequest) async throws -> [NativeReminder] {
        searches.append(request)
        return searchResults
    }
}
```

- [ ] **Step 2: Run failing capability test**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter NativeCapabilityToolsTests/remindersSearchUsesInjectedFacade
```

Expected: FAIL because reminder search types and tool do not exist.

- [ ] **Step 3: Add reminder search DTOs and facade method**

Modify `ReminderTools.swift`:

```swift
public struct NativeReminderSearchRequest: Codable, Equatable, Sendable {
    public var query: String?
    public var includeCompleted: Bool
    public var dueFromISO8601: String?
    public var dueToISO8601: String?
    public var limit: Int

    public init(
        query: String?,
        includeCompleted: Bool,
        dueFromISO8601: String?,
        dueToISO8601: String?,
        limit: Int
    ) {
        self.query = query
        self.includeCompleted = includeCompleted
        self.dueFromISO8601 = dueFromISO8601
        self.dueToISO8601 = dueToISO8601
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey {
        case query
        case includeCompleted = "include_completed"
        case dueFromISO8601 = "due_from"
        case dueToISO8601 = "due_to"
        case limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.query = try container.decodeIfPresent(String.self, forKey: .query)
        self.includeCompleted = try container.decodeIfPresent(Bool.self, forKey: .includeCompleted) ?? false
        self.dueFromISO8601 = try container.decodeIfPresent(String.self, forKey: .dueFromISO8601)
        self.dueToISO8601 = try container.decodeIfPresent(String.self, forKey: .dueToISO8601)
        self.limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 20
    }
}

public protocol RemindersFacade: Sendable {
    func createReminder(_ request: NativeReminderCreateRequest) async throws -> NativeReminder
    func searchReminders(_ request: NativeReminderSearchRequest) async throws -> [NativeReminder]
}
```

Add a temporary default for adopters during this task:

```swift
public extension RemindersFacade {
    func searchReminders(_ request: NativeReminderSearchRequest) async throws -> [NativeReminder] {
        []
    }
}
```

- [ ] **Step 4: Add `RemindersSearchRemindersTool`**

Append to `ReminderTools.swift`:

```swift
public struct RemindersSearchRemindersTool: NativeTool {
    public let schema: NativeToolSchema
    private let reminders: any RemindersFacade

    public init(reminders: any RemindersFacade) {
        self.schema = Self.makeSchema()
        self.reminders = reminders
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        do {
            let request = try Self.decode(NativeReminderSearchRequest.self, from: argumentsJson)
            let bounded = NativeReminderSearchRequest(
                query: request.query,
                includeCompleted: request.includeCompleted,
                dueFromISO8601: request.dueFromISO8601,
                dueToISO8601: request.dueToISO8601,
                limit: min(max(request.limit, 1), 50)
            )
            let results = try await reminders.searchReminders(bounded)
            return NativeToolResultBuilder.success(
                manifestId: Self.manifest.manifestId,
                toolName: schema.name,
                toolCallId: "unknown",
                displayText: "\(results.count) reminders found.",
                modelText: "Reminders found: \(results.map(\.title).joined(separator: ", "))",
                resultKind: "reminders",
                resultPayload: [
                    "count": .number(Double(results.count)),
                    "reminders": .array(results.map(Self.reminderJSONValue)),
                ],
                sourceKind: "reminders",
                sourceId: "reminders.search_reminders",
                displayName: Self.manifest.title,
                attachmentIds: [],
                trustLevel: Self.manifest.trustLevel,
                sensitivity: .private,
                retention: Self.manifest.retention,
                modelTextPolicy: "tool_status",
                sourceLabel: "Reminders",
                auditSummary: "Searched reminders.",
                auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
            )
        } catch {
            return NativeToolResultBuilder.error(
                manifestId: Self.manifest.manifestId,
                toolName: "reminders.search_reminders",
                toolCallId: "unknown",
                code: "reminders_search_failed",
                displayText: "Unable to search reminders.",
                auditSummary: "Reminder search failed.",
                sensitivity: .private,
                retention: Self.manifest.retention
            )
        }
    }

    private static var manifest: NativeToolManifest {
        NativeToolManifest(
            manifestId: "native.reminders.search_reminders.v1",
            capabilityId: "reminders.search_reminders",
            title: "Find Reminders",
            description: "Search local reminders.",
            mode: .background,
            permissionScope: NativePermissionScope("reminders"),
            requiredPrivacyKeys: ["NSRemindersUsageDescription"],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .openSettings, message: "Reminders access is required."),
            riskLevel: .readOnly,
            approvalPolicy: .perCall,
            trustLevel: .trustedToolResult,
            retention: .runOnly,
            audit: NativeToolAudit(label: "Find Reminders", resultSummaryPolicy: .metadataOnly)
        )
    }

    private static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "reminders.search_reminders",
            description: manifest.description,
            inputSchema: .object(
                properties: [
                    "query": .string(),
                    "include_completed": .string(),
                    "due_from": .string(),
                    "due_to": .string(),
                    "limit": .string(),
                ],
                required: []
            ),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func reminderJSONValue(_ reminder: NativeReminder) -> JSONValue {
        .object([
            "reminder_id": .string(reminder.id),
            "title": .string(reminder.title),
            "notes": .string(reminder.notes ?? ""),
            "due_date": .string(reminder.dueDateISO8601 ?? ""),
            "is_completed": .bool(false),
            "list_title": .string(""),
        ])
    }
}
```

- [ ] **Step 5: Add EventKit reminder search adapter**

Modify `EventKitReminderAdapter`:

```swift
public protocol EventKitReminderWriting: Sendable {
    func createReminder(_ request: NativeReminderCreateRequest) async throws -> NativeReminder
    func searchReminders(_ request: NativeReminderSearchRequest) async throws -> [NativeReminder]
}

public func searchReminders(_ request: NativeReminderSearchRequest) async throws -> [NativeReminder] {
    try await writer.searchReminders(request)
}
```

Inside `EKEventStoreReminderWriter` add:

```swift
public func searchReminders(_ request: NativeReminderSearchRequest) async throws -> [NativeReminder] {
    let predicate = eventStore.predicateForReminders(in: nil)
    let reminders = try await withCheckedThrowingContinuation { continuation in
        eventStore.fetchReminders(matching: predicate) { reminders in
            continuation.resume(returning: reminders ?? [])
        }
    }
    let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return reminders
        .filter { reminder in
            request.includeCompleted || !reminder.isCompleted
        }
        .filter { reminder in
            guard let query, !query.isEmpty else {
                return true
            }
            return reminder.title.lowercased().contains(query)
        }
        .prefix(request.limit)
        .map { reminder in
            NativeReminder(
                id: reminder.calendarItemIdentifier,
                title: reminder.title,
                notes: reminder.notes,
                dueDateISO8601: reminder.dueDateComponents?.date.map(Self.iso8601)
            )
        }
}

private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}
```

- [ ] **Step 6: Run capability tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter NativeCapabilityToolsTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/ReminderTools.swift local-ios-agent/toolkit/Sources/LocalNativeToolkit/EventKit/EventKitReminderAdapter.swift local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeCapabilityToolsTests.swift
git commit -m "feat: add reminders search tool"
```

---

## Task 7: Add `calendar.find_free_time`

**Files:**
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/CalendarTools.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/EventKit/EventKitCalendarAdapter.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeCapabilityToolsTests.swift`

- [ ] **Step 1: Add failing free-time test**

Append to `NativeCapabilityToolsTests`:

```swift
@Test
func calendarFindFreeTimeReturnsCandidateSlots() async throws {
    let facade = RecordingCalendarFacade(events: [
        NativeCalendarEvent(
            id: "busy_1",
            title: "Busy",
            startDateISO8601: "2026-07-10T09:00:00Z",
            endDateISO8601: "2026-07-10T10:00:00Z"
        ),
    ])
    let tool = CalendarFindFreeTimeTool(calendar: facade)

    let result = await tool.execute(
        argumentsJson: #"{"duration_minutes":60,"search_from":"2026-07-10T09:00:00Z","search_to":"2026-07-10T12:00:00Z","limit":2}"#
    )
    let object = try decodedJSONObject(result.structuredJson)
    let payload = try #require(object["result"] as? [String: Any])
    let candidates = try #require(payload["candidates"] as? [[String: Any]])

    #expect(result.isError == false)
    #expect(tool.schema.name == "calendar.find_free_time")
    #expect(candidates.first?["start_date"] as? String == "2026-07-10T10:00:00Z")
}
```

Add method support to `RecordingCalendarFacade`:

```swift
func eventsBetween(startDateISO8601: String, endDateISO8601: String) async throws -> [NativeCalendarEvent] {
    events
}
```

- [ ] **Step 2: Run failing free-time test**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter NativeCapabilityToolsTests/calendarFindFreeTimeReturnsCandidateSlots
```

Expected: FAIL because `CalendarFindFreeTimeTool` and `eventsBetween` do not exist.

- [ ] **Step 3: Extend calendar facade**

Modify `CalendarTools.swift`:

```swift
public protocol CalendarEventsFacade: Sendable {
    func searchEvents(query: String) async throws -> [NativeCalendarEvent]
    func eventsBetween(startDateISO8601: String, endDateISO8601: String) async throws -> [NativeCalendarEvent]
}

public extension CalendarEventsFacade {
    func eventsBetween(startDateISO8601: String, endDateISO8601: String) async throws -> [NativeCalendarEvent] {
        try await searchEvents(query: "")
    }
}
```

- [ ] **Step 4: Implement `CalendarFindFreeTimeTool`**

Append to `CalendarTools.swift`:

```swift
public struct CalendarFindFreeTimeTool: NativeTool {
    public let schema: NativeToolSchema
    private let calendar: any CalendarEventsFacade

    public init(calendar: any CalendarEventsFacade) {
        self.schema = Self.makeSchema()
        self.calendar = calendar
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        do {
            let request = try Self.decode(CalendarFindFreeTimeRequest.self, from: argumentsJson)
            let events = try await calendar.eventsBetween(
                startDateISO8601: request.searchFromISO8601,
                endDateISO8601: request.searchToISO8601
            )
            let candidates = Self.findSlots(request: request, events: events)
            return NativeToolResultBuilder.success(
                manifestId: Self.manifest.manifestId,
                toolName: schema.name,
                toolCallId: "unknown",
                displayText: "\(candidates.count) free slots found.",
                modelText: "Free calendar slots: \(candidates.map { "\($0.startDateISO8601)-\($0.endDateISO8601)" }.joined(separator: ", "))",
                resultKind: "calendar_free_time",
                resultPayload: [
                    "candidates": .array(candidates.map { candidate in
                        .object([
                            "start_date": .string(candidate.startDateISO8601),
                            "end_date": .string(candidate.endDateISO8601),
                            "confidence": .string(candidate.confidence),
                        ])
                    }),
                ],
                sourceKind: "calendar",
                sourceId: "calendar.find_free_time",
                displayName: Self.manifest.title,
                attachmentIds: [],
                trustLevel: Self.manifest.trustLevel,
                sensitivity: .private,
                retention: Self.manifest.retention,
                modelTextPolicy: "tool_status",
                sourceLabel: "Calendar",
                auditSummary: "Found calendar free time.",
                auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
            )
        } catch {
            return NativeToolResultBuilder.error(
                manifestId: Self.manifest.manifestId,
                toolName: "calendar.find_free_time",
                toolCallId: "unknown",
                code: "calendar_find_free_time_failed",
                displayText: "Unable to find calendar free time.",
                auditSummary: "Calendar free-time search failed.",
                sensitivity: .private,
                retention: Self.manifest.retention
            )
        }
    }

    private static var manifest: NativeToolManifest {
        NativeToolManifest(
            manifestId: "native.calendar.find_free_time.v1",
            capabilityId: "calendar.find_free_time",
            title: "Find Free Time",
            description: "Find free calendar slots.",
            mode: .background,
            permissionScope: NativePermissionScope("calendar.events.read_full"),
            requiredPrivacyKeys: ["NSCalendarsFullAccessUsageDescription"],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .openSettings, message: "Calendar access is required."),
            riskLevel: .readOnly,
            approvalPolicy: .perCall,
            trustLevel: .trustedToolResult,
            retention: .runOnly,
            audit: NativeToolAudit(label: "Find Free Time", resultSummaryPolicy: .metadataOnly)
        )
    }

    private static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "calendar.find_free_time",
            description: manifest.description,
            inputSchema: .object(
                properties: [
                    "duration_minutes": .string(),
                    "search_from": .string(),
                    "search_to": .string(),
                    "working_hours_only": .string(),
                    "limit": .string(),
                ],
                required: ["duration_minutes", "search_from", "search_to"]
            ),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func findSlots(request: CalendarFindFreeTimeRequest, events: [NativeCalendarEvent]) -> [CalendarFreeTimeCandidate] {
        let formatter = ISO8601DateFormatter()
        guard let start = formatter.date(from: request.searchFromISO8601),
              let end = formatter.date(from: request.searchToISO8601)
        else {
            return []
        }
        let duration = TimeInterval(max(1, request.durationMinutes) * 60)
        var cursor = start
        let busy = events.compactMap { event -> (Date, Date)? in
            guard let eventStart = formatter.date(from: event.startDateISO8601) else {
                return nil
            }
            let eventEnd = event.endDateISO8601.flatMap(formatter.date(from:)) ?? eventStart.addingTimeInterval(3600)
            return (eventStart, eventEnd)
        }.sorted { $0.0 < $1.0 }

        var candidates: [CalendarFreeTimeCandidate] = []
        for interval in busy {
            if cursor.addingTimeInterval(duration) <= interval.0 {
                candidates.append(CalendarFreeTimeCandidate(
                    startDateISO8601: iso8601(cursor),
                    endDateISO8601: iso8601(cursor.addingTimeInterval(duration)),
                    confidence: "high"
                ))
            }
            cursor = max(cursor, interval.1)
        }
        if cursor.addingTimeInterval(duration) <= end {
            candidates.append(CalendarFreeTimeCandidate(
                startDateISO8601: iso8601(cursor),
                endDateISO8601: iso8601(cursor.addingTimeInterval(duration)),
                confidence: "high"
            ))
        }
        return Array(candidates.prefix(max(1, request.limit)))
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private struct CalendarFindFreeTimeRequest: Decodable {
    var durationMinutes: Int
    var searchFromISO8601: String
    var searchToISO8601: String
    var workingHoursOnly: Bool?
    var limit: Int

    private enum CodingKeys: String, CodingKey {
        case durationMinutes = "duration_minutes"
        case searchFromISO8601 = "search_from"
        case searchToISO8601 = "search_to"
        case workingHoursOnly = "working_hours_only"
        case limit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.durationMinutes = try container.decode(Int.self, forKey: .durationMinutes)
        self.searchFromISO8601 = try container.decode(String.self, forKey: .searchFromISO8601)
        self.searchToISO8601 = try container.decode(String.self, forKey: .searchToISO8601)
        self.workingHoursOnly = try container.decodeIfPresent(Bool.self, forKey: .workingHoursOnly)
        self.limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 5
    }
}

private struct CalendarFreeTimeCandidate {
    var startDateISO8601: String
    var endDateISO8601: String
    var confidence: String
}
```

- [ ] **Step 5: Add EventKit range implementation**

Modify `EventKitCalendarAdapter`:

```swift
public func eventsBetween(startDateISO8601: String, endDateISO8601: String) async throws -> [NativeCalendarEvent] {
    let formatter = ISO8601DateFormatter()
    guard let startDate = formatter.date(from: startDateISO8601),
          let endDate = formatter.date(from: endDateISO8601)
    else {
        return []
    }
    let events = try await source.events(from: startDate, to: endDate)
    return events
        .sorted { lhs, rhs in
            if lhs.startDate == rhs.startDate {
                return lhs.title < rhs.title
            }
            return lhs.startDate < rhs.startDate
        }
        .map { event in
            NativeCalendarEvent(
                id: event.id,
                title: event.title,
                startDateISO8601: Self.iso8601(event.startDate),
                endDateISO8601: event.endDate.map(Self.iso8601)
            )
        }
}
```

- [ ] **Step 6: Run calendar tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter NativeCapabilityToolsTests/calendarFindFreeTimeReturnsCandidateSlots
swift test --package-path local-ios-agent/toolkit --filter NativeCapabilityToolsTests/calendarSearchEventsUsesInjectedFacade
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/CalendarTools.swift local-ios-agent/toolkit/Sources/LocalNativeToolkit/EventKit/EventKitCalendarAdapter.swift local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeCapabilityToolsTests.swift
git commit -m "feat: add calendar free time tool"
```

---

## Task 8: Add `calendar.create_event_user_confirmed`

**Files:**
- Modify: `local-ios-agent/toolkit/Sources/LocalNativeToolkit/CalendarTools.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeCapabilityToolsTests.swift`

- [ ] **Step 1: Add failing calendar confirmation tool test**

Append to `NativeCapabilityToolsTests`:

```swift
@Test
func calendarCreateEventUserConfirmedReturnsPendingInteraction() async throws {
    let tool = CalendarCreateEventUserConfirmedTool()

    let result = await tool.execute(
        argumentsJson: #"{"title":"Dentist","start_date":"2026-07-10T10:00:00Z","end_date":"2026-07-10T11:00:00Z","notes":"Bring card","location":"Clinic"}"#
    )
    let object = try decodedJSONObject(result.structuredJson)
    let payload = try #require(object["result"] as? [String: Any])
    let provenance = try #require(object["provenance"] as? [String: Any])

    #expect(tool.schema.name == "calendar.create_event_user_confirmed")
    #expect(tool.schema.manifest?.mode == .userMediated)
    #expect(tool.schema.manifest?.permissionScope == NativePermissionScope("calendar.events.user_confirmed_create"))
    #expect(result.isError == false)
    #expect(payload["interaction_kind"] as? String == "system_confirmation")
    #expect(payload["title"] as? String == "Dentist")
    #expect(provenance["trust_level"] as? String == "trusted_tool_result")
}
```

- [ ] **Step 2: Run failing confirmation tool test**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter NativeCapabilityToolsTests/calendarCreateEventUserConfirmedReturnsPendingInteraction
```

Expected: FAIL because `CalendarCreateEventUserConfirmedTool` does not exist.

- [ ] **Step 3: Implement pending interaction tool**

Append to `CalendarTools.swift`:

```swift
public struct CalendarCreateEventUserConfirmedTool: NativeTool {
    public let schema: NativeToolSchema

    public init() {
        self.schema = Self.makeSchema()
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        do {
            let request = try Self.decode(CalendarCreateEventUserConfirmedRequest.self, from: argumentsJson)
            return NativeToolResultBuilder.success(
                manifestId: Self.manifest.manifestId,
                toolName: schema.name,
                toolCallId: "unknown",
                displayText: "Calendar event needs confirmation: \(request.title)",
                modelText: "Calendar event creation is waiting for user confirmation.",
                resultKind: "pending_user_interaction",
                resultPayload: [
                    "interaction_kind": .string(PendingInteractionKind.systemConfirmation.rawValue),
                    "title": .string(request.title),
                    "start_date": .string(request.startDateISO8601),
                    "end_date": .string(request.endDateISO8601),
                    "notes": .string(request.notes ?? ""),
                    "location": .string(request.location ?? ""),
                    "status": .string("pending_user_confirmation"),
                ],
                sourceKind: "calendar",
                sourceId: "calendar.create_event_user_confirmed",
                displayName: Self.manifest.title,
                attachmentIds: [],
                trustLevel: Self.manifest.trustLevel,
                sensitivity: .private,
                retention: Self.manifest.retention,
                modelTextPolicy: "tool_status",
                sourceLabel: "Calendar",
                auditSummary: "Requested user-confirmed calendar event.",
                auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
            )
        } catch {
            return NativeToolResultBuilder.error(
                manifestId: Self.manifest.manifestId,
                toolName: "calendar.create_event_user_confirmed",
                toolCallId: "unknown",
                code: "calendar_event_invalid_arguments",
                displayText: "Expected title, start_date, and end_date.",
                auditSummary: "Calendar event confirmation failed: invalid arguments.",
                sensitivity: .private,
                retention: Self.manifest.retention
            )
        }
    }

    private static var manifest: NativeToolManifest {
        NativeToolManifest(
            manifestId: "native.calendar.create_event_user_confirmed.v1",
            capabilityId: "calendar.create_event_user_confirmed",
            title: "Create Calendar Event",
            description: "Prepare a calendar event and ask the user to confirm it.",
            mode: .userMediated,
            permissionScope: NativePermissionScope("calendar.events.user_confirmed_create"),
            requiredPrivacyKeys: [],
            requiresForegroundUI: true,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .userMediated, message: "Open the app to confirm the event."),
            riskLevel: .confirm,
            approvalPolicy: .perCall,
            trustLevel: .trustedToolResult,
            retention: .runOnly,
            audit: NativeToolAudit(label: "Create Calendar Event", resultSummaryPolicy: .metadataOnly)
        )
    }

    private static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "calendar.create_event_user_confirmed",
            description: manifest.description,
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "start_date": .string(),
                    "end_date": .string(),
                    "notes": .string(),
                    "location": .string(),
                ],
                required: ["title", "start_date", "end_date"]
            ),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(type, from: data)
    }
}

private struct CalendarCreateEventUserConfirmedRequest: Decodable {
    var title: String
    var startDateISO8601: String
    var endDateISO8601: String
    var notes: String?
    var location: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case startDateISO8601 = "start_date"
        case endDateISO8601 = "end_date"
        case notes
        case location
    }
}
```

- [ ] **Step 4: Run confirmation tool tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter NativeCapabilityToolsTests/calendarCreateEventUserConfirmedReturnsPendingInteraction
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit/CalendarTools.swift local-ios-agent/toolkit/Tests/LocalNativeToolkitTests/NativeCapabilityToolsTests.swift
git commit -m "feat: add calendar confirmation tool"
```

---

## Task 9: Register Tool Pack In Native Catalog Assembly

**Files:**
- Inspect/modify the app bootstrap file that constructs `NativeToolCatalog`.
- Likely modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
- Test: existing app-level tests if a native toolkit bootstrap test exists; otherwise add a narrow unit test around the catalog factory if one exists.

- [ ] **Step 1: Locate catalog construction**

Run:

```bash
rg "NativeToolCatalog|NativeListToolsTool|WebFetchURLTextTool|CalendarSearchEventsTool|RemindersCreateReminderTool" local-ios-agent/apps local-ios-agent/toolkit/Sources -n
```

Expected: find the production catalog assembly. If the catalog is currently created inline in `AppBootstrapper`, keep this task scoped to that file and do not introduce a broad app architecture refactor.

- [ ] **Step 2: Add the new tools to the production catalog**

The catalog should include the new runtime tools with existing dependencies:

```swift
let attachmentStore = /* existing NativeAttachmentByteStore */
let calendarFacade = /* existing CalendarEventsFacade */
let remindersFacade = /* existing RemindersFacade */

let nativeTools: [any NativeTool] = [
    NativePermissionStatusTool(permissionStore: permissionStore),
    WebFetchURLTextTool(),
    WebExtractReadableArticleTool(),
    AttachmentsListTool(store: attachmentStore),
    FilesDescribeAttachmentTool(store: attachmentStore),
    FilesReadAttachmentTool(store: attachmentStore),
    PhotosDescribeAttachmentTool(store: attachmentStore),
    VisionExtractTextFromAttachmentTool(
        store: attachmentStore,
        recognizer: {
            #if canImport(Vision)
            VisionTextRecognitionAdapter()
            #else
            UnavailableVisionTextRecognizer()
            #endif
        }()
    ),
    CalendarSearchEventsTool(calendar: calendarFacade),
    CalendarFindFreeTimeTool(calendar: calendarFacade),
    CalendarCreateEventUserConfirmedTool(),
    RemindersCreateReminderTool(reminders: remindersFacade),
    RemindersSearchRemindersTool(reminders: remindersFacade),
]

let catalog = try NativeToolCatalog(tools: nativeTools)
let listTools = NativeListToolsTool(catalogProvider: { catalog })
```

If the existing implementation builds `NativeListToolsTool` before the final catalog exists, use the existing `catalogProvider` pattern from `MetaToolsTests` with a small boxed catalog.

- [ ] **Step 3: Keep system input capabilities out of this runtime catalog**

Do not add these to the runtime catalog:

```swift
share.capture_input
agent.capture_text
agent.start_chat
agent.continue_conversation
```

They belong to App Intents / Share Extension routing, not `NativeToolCatalog`.

- [ ] **Step 4: Run native toolkit tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit --filter LocalNativeToolkitTests
```

Expected: PASS.

- [ ] **Step 5: If app-level catalog tests exist, run them**

Run:

```bash
swift test --package-path local-ios-agent/toolkit
```

Expected: PASS for all toolkit tests. If app-level tests are available through Xcode, run them later in final verification using the fixed `xcodebuild` path, not `DEVELOPER_DIR=... xcodebuild`.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift
git commit -m "feat: register native tool pack"
```

If Task 9 creates or modifies a catalog factory file instead of `AppBootstrapper.swift`, stage that actual file path instead.

---

## Task 10: Final Verification And Self-Review

**Files:**
- No new source files expected.

- [ ] **Step 1: Run full toolkit tests**

Run:

```bash
swift test --package-path local-ios-agent/toolkit
```

Expected: PASS.

- [ ] **Step 2: Run focused grep checks for export boundary**

Run:

```bash
rg "share.capture_input|agent.capture_text|agent.continue_conversation" local-ios-agent/toolkit/Sources/LocalNativeToolkit local-ios-agent/apps/LocalAgentApp -n
```

Expected:

- These names may appear in App Intent / Share Extension routing in later work.
- They must not appear as `NativeToolSchema(name:)` entries in the runtime `NativeToolCatalog`.

- [ ] **Step 3: Review result envelopes**

Run:

```bash
rg "NativeToolResultBuilder.success|ToolResultEnvelopeV1|untrustedExternalContent|trustedToolResult" local-ios-agent/toolkit/Sources/LocalNativeToolkit -n
```

Expected:

- `web.extract_readable_article`, `vision.extract_text_from_attachment`, and `files.read_attachment` use `.untrustedExternalContent`.
- `attachments.list`, `calendar.*`, and `reminders.*` use `.trustedToolResult`.
- All new tools return `ToolResultEnvelopeV1` through `NativeToolResultBuilder`.

- [ ] **Step 4: Self-review P1 issues**

Review the diff manually:

```bash
git diff master...HEAD -- local-ios-agent/toolkit/Sources/LocalNativeToolkit local-ios-agent/toolkit/Tests/LocalNativeToolkitTests
```

Check:

- No system input capability is exported to Rust.
- No model-visible tool output includes raw file paths or security-scoped bookmark data.
- Web readable extraction does not execute JavaScript.
- OCR consumes attachment ids only.
- Calendar user-confirmed creation returns pending interaction data, not a fake durable event id.
- Reminder and calendar result lists are bounded.

- [ ] **Step 5: Commit final fixes if needed**

If Step 4 finds fixes, make only those fixes and commit:

```bash
git add local-ios-agent/toolkit/Sources/LocalNativeToolkit local-ios-agent/toolkit/Tests/LocalNativeToolkitTests
git commit -m "fix: harden native tool pack boundaries"
```

If Step 4 finds no fixes, do not create an empty commit.

---

## Plan Self-Review

### Spec Coverage

- `attachments.list`: Task 2 and Task 3.
- `web.extract_readable_article`: Task 4.
- `vision.extract_text_from_attachment`: Task 5.
- `reminders.search_reminders`: Task 6.
- `calendar.find_free_time`: Task 7.
- `calendar.create_event_user_confirmed`: Task 8.
- System input non-export: Task 1 and Task 10.
- Runtime registration: Task 9.
- Testing and self-review: Task 10.

### Intentional Deferrals

- `share.capture_input`: system input design only; not implemented in this runtime tool pack.
- `agent.capture_text`, `agent.start_chat`, `agent.continue_conversation`: App Intent layer; not implemented here.
- `vision.scan_document`: user-mediated scanner UI; separate plan.
- `notifications.schedule_local`: visible follow-up tool; separate plan.
- Maps tools and visible web handoff: separate plan.
- PDF, speech, mail, contacts, HealthKit, HomeKit: out of scope.

### Commands

Use SwiftPM for this plan:

```bash
swift test --package-path local-ios-agent/toolkit --filter LocalNativeToolkitTests
swift test --package-path local-ios-agent/toolkit
```

Use Xcode only for later app-level verification, and use the fixed path:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
```

Do not use:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild
```
