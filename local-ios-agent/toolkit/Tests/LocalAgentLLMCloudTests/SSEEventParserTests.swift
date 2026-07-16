import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("Bounded incremental SSE parser")
struct SSEEventParserTests {
    @Test
    func fragmentedUTF8AndCRLFBoundariesPreserveFields() throws {
        var parser = SSEEventParser()
        let bytes = Data("event: message\r\nid: evt-7\r\nretry: 1500\r\ndata: hello \u{1F30D}\r\n\r\n".utf8)
        let globeStart = try #require(bytes.firstRange(of: Data("\u{1F30D}".utf8))?.lowerBound)
        let cuts = [5, globeStart + 1, globeStart + 3, bytes.count - 1]
        var start = 0
        var events: [SSEEvent] = []
        for end in cuts + [bytes.count] where end > start {
            events.append(contentsOf: try parser.append(bytes.subdata(in: start..<end)))
            start = end
        }
        events.append(contentsOf: try parser.finish())

        #expect(events == [SSEEvent(
            event: "message",
            id: "evt-7",
            retryMilliseconds: 1_500,
            data: Data("hello \u{1F30D}".utf8)
        )])
    }

    @Test
    func multilineDataCommentsEmptyBlocksAndPingEventsFollowSSEFraming() throws {
        var parser = SSEEventParser()
        let events = try parser.append(Data("""
        : keepalive


        event: ping
        data:

        data: first
        data: second
        ignored: value

        """.utf8)) + parser.finish()

        #expect(events == [
            SSEEvent(event: "ping", id: nil, retryMilliseconds: nil, data: Data()),
            SSEEvent(event: nil, id: nil, retryMilliseconds: nil, data: Data("first\nsecond".utf8)),
        ])
    }

    @Test
    func acceptsValuesAtConfiguredLimits() throws {
        var parser = SSEEventParser(
            limits: .init(maxLineBytes: 16, maxEventBytes: 32, maxBufferedBytes: 64)
        )
        let data = Data("data: 1234567890\n\n".utf8)
        #expect(try parser.append(data).single?.data == Data("1234567890".utf8))
        #expect(try parser.finish().isEmpty)
    }

    @Test(arguments: [
        ("line", Data("data: 12345678901".utf8), SSEParserLimits(maxLineBytes: 16, maxEventBytes: 64, maxBufferedBytes: 128), "cloud_sse.line_too_large"),
        ("event", Data("data: 1234567890\ndata: 1234567890\n\n".utf8), SSEParserLimits(maxLineBytes: 32, maxEventBytes: 20, maxBufferedBytes: 128), "cloud_sse.event_too_large"),
        ("buffer", Data(repeating: 0x61, count: 17), SSEParserLimits(maxLineBytes: 16, maxEventBytes: 16, maxBufferedBytes: 16), "cloud_sse.buffer_too_large"),
    ])
    func rejectsConfiguredSizeOverflows(
        label: String,
        bytes: Data,
        limits: SSEParserLimits,
        code: String
    ) {
        _ = label
        var parser = SSEEventParser(limits: limits)
        do {
            _ = try parser.append(bytes)
            Issue.record("expected SSE limit failure")
        } catch let failure as LLMFailure {
            #expect(failure.code == code)
            #expect(failure.redactedDiagnostics.isEmpty)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func invalidUTF8FailsWithoutEchoingBytes() {
        var parser = SSEEventParser()
        do {
            _ = try parser.append(Data([0x64, 0x61, 0x74, 0x61, 0x3a, 0x20, 0xFF, 0x0A, 0x0A]))
            Issue.record("expected invalid UTF-8 failure")
        } catch let failure as LLMFailure {
            #expect(failure.code == "cloud_sse.invalid_utf8")
            #expect(!failure.message.contains("255"))
            #expect(failure.redactedDiagnostics.isEmpty)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func finishDispatchesFinalUnterminatedEventAndRejectsDanglingInvalidUTF8() throws {
        var parser = SSEEventParser()
        #expect(try parser.append(Data("data: final".utf8)).isEmpty)
        #expect(try parser.finish().single?.data == Data("final".utf8))

        var invalid = SSEEventParser()
        #expect(try invalid.append(Data([0x64, 0x61, 0x74, 0x61, 0x3a, 0x20, 0xE2])).isEmpty)
        do {
            _ = try invalid.finish()
            Issue.record("expected invalid UTF-8 failure")
        } catch let failure as LLMFailure {
            #expect(failure.code == "cloud_sse.invalid_utf8")
        }
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
