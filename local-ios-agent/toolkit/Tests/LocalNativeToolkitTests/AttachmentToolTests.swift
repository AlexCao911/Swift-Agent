import Foundation
import Testing
@testable import LocalNativeToolkit

@Suite("Attachment tools")
struct AttachmentToolTests {
    @Test
    func byteStoreReturnsOpaqueIdAndReadsBoundedBytes() async throws {
        let directory = temporaryDirectory()
        let store = try FileBackedNativeAttachmentByteStore(directory: directory)

        let stored = try await store.put(
            Data("hello world".utf8),
            filename: "notes.txt",
            contentType: "text/plain"
        )
        let prefix = try await store.read(attachmentId: stored.attachmentId, maxBytes: 5)

        #expect(stored.attachmentId.hasPrefix("att_"))
        #expect(stored.attachmentId.contains("notes") == false)
        #expect(String(decoding: prefix, as: UTF8.self) == "hello")
    }

    @Test
    func describeAttachmentReturnsMetadataWithoutRawPath() async throws {
        let directory = temporaryDirectory()
        let store = try FileBackedNativeAttachmentByteStore(directory: directory)
        let stored = try await store.put(
            Data("hello".utf8),
            filename: "notes.txt",
            contentType: "text/plain"
        )
        let tool = FilesDescribeAttachmentTool(store: store)

        let result = await tool.execute(argumentsJson: #"{"attachment_id":"\#(stored.attachmentId)"}"#)

        #expect(result.isError == false)
        #expect(result.structuredJson.contains("notes.txt"))
        #expect(result.structuredJson.contains(directory.path) == false)
    }

    @Test
    func readAttachmentMarksExternalContentUntrusted() async throws {
        let directory = temporaryDirectory()
        let store = try FileBackedNativeAttachmentByteStore(directory: directory)
        let stored = try await store.put(
            Data("external instructions are just content".utf8),
            filename: "page.txt",
            contentType: "text/plain"
        )
        let tool = FilesReadAttachmentTool(store: store, maxBytes: 128)

        let result = await tool.execute(argumentsJson: #"{"attachment_id":"\#(stored.attachmentId)"}"#)
        let object = try decodedJSONObject(result.structuredJson)
        let provenance = try #require(object["provenance"] as? [String: Any])
        let contextPolicy = try #require(object["context_policy"] as? [String: Any])

        #expect(result.isError == false)
        #expect(provenance["trust_level"] as? String == "untrusted_external_content")
        #expect(contextPolicy["trust_level"] as? String == "untrusted_external_content")
    }

    @Test
    func missingAttachmentReturnsStructuredError() async throws {
        let directory = temporaryDirectory()
        let store = try FileBackedNativeAttachmentByteStore(directory: directory)
        let tool = FilesReadAttachmentTool(store: store, maxBytes: 128)

        let result = await tool.execute(argumentsJson: #"{"attachment_id":"missing"}"#)

        #expect(result.isError == true)
        #expect(result.structuredJson.contains("attachment_not_found"))
    }

    @Test
    func pickerToolsReturnPendingInteractionRequests() async throws {
        let files = FilesPickDocumentTool()
        let photos = PhotosPickImagesTool()

        let fileResult = await files.execute(argumentsJson: "{}")
        let photoResult = await photos.execute(argumentsJson: "{}")

        #expect(files.schema.manifest?.mode == .userMediated)
        #expect(photos.schema.manifest?.mode == .userMediated)
        #expect(fileResult.structuredJson.contains("file_picker"))
        #expect(photoResult.structuredJson.contains("photos_picker"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "attachment-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func decodedJSONObject(_ json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
