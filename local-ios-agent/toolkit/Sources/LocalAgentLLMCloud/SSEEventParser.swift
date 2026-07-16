import Foundation
import LocalAgentLLMContracts

package struct SSEParserLimits: Equatable, Sendable {
    package let maxLineBytes: Int
    package let maxEventBytes: Int
    package let maxBufferedBytes: Int

    package init(
        maxLineBytes: Int = 64 * 1_024,
        maxEventBytes: Int = 1_024 * 1_024,
        maxBufferedBytes: Int = 2 * 1_024 * 1_024
    ) {
        self.maxLineBytes = maxLineBytes
        self.maxEventBytes = maxEventBytes
        self.maxBufferedBytes = maxBufferedBytes
    }

    fileprivate func validate() throws {
        guard maxLineBytes > 0,
              maxEventBytes > 0,
              maxBufferedBytes > 0,
              maxLineBytes <= maxBufferedBytes,
              maxEventBytes <= maxBufferedBytes
        else {
            throw sseFailure("cloud_sse.limits_invalid", "SSE parser limits are invalid")
        }
    }
}

package struct SSEEventParser: Sendable {
    private let limits: SSEParserLimits
    private var buffer = Data()
    private var dataLines: [Data] = []
    private var eventName: String?
    private var eventID: String?
    private var retryMilliseconds: UInt64?
    private var assembledEventBytes = 0
    private var finished = false

    package init(limits: SSEParserLimits = SSEParserLimits()) {
        self.limits = limits
    }

    package mutating func append(_ bytes: Data) throws -> [SSEEvent] {
        guard !finished else {
            throw sseFailure("cloud_sse.already_finished", "SSE parser is already finished")
        }
        try limits.validate()
        guard bytes.count <= limits.maxBufferedBytes - buffer.count else {
            throw sseFailure("cloud_sse.buffer_too_large", "SSE undecoded buffer exceeded its limit")
        }
        buffer.append(bytes)
        var events: [SSEEvent] = []
        while let boundary = nextLineBoundary(final: false) {
            let line = buffer.subdata(in: 0..<boundary.lineEnd)
            buffer.removeSubrange(0..<boundary.consumedEnd)
            guard line.count <= limits.maxLineBytes else {
                throw sseFailure("cloud_sse.line_too_large", "SSE line exceeded its limit")
            }
            if let event = try consume(line) { events.append(event) }
        }
        if buffer.count > limits.maxLineBytes {
            throw sseFailure("cloud_sse.line_too_large", "SSE line exceeded its limit")
        }
        return events
    }

    package mutating func finish() throws -> [SSEEvent] {
        guard !finished else { return [] }
        try limits.validate()
        finished = true
        var events: [SSEEvent] = []
        while let boundary = nextLineBoundary(final: true) {
            let line = buffer.subdata(in: 0..<boundary.lineEnd)
            buffer.removeSubrange(0..<boundary.consumedEnd)
            guard line.count <= limits.maxLineBytes else {
                throw sseFailure("cloud_sse.line_too_large", "SSE line exceeded its limit")
            }
            if let event = try consume(line) { events.append(event) }
        }
        if !buffer.isEmpty {
            guard buffer.count <= limits.maxLineBytes else {
                throw sseFailure("cloud_sse.line_too_large", "SSE line exceeded its limit")
            }
            let line = buffer
            buffer.removeAll(keepingCapacity: false)
            if let event = try consume(line) { events.append(event) }
        }
        if let event = dispatchEvent() { events.append(event) }
        return events
    }

    private func nextLineBoundary(final: Bool) -> (lineEnd: Int, consumedEnd: Int)? {
        var index = buffer.startIndex
        while index < buffer.endIndex {
            switch buffer[index] {
            case 0x0A:
                return (index, buffer.index(after: index))
            case 0x0D:
                let after = buffer.index(after: index)
                if after < buffer.endIndex, buffer[after] == 0x0A {
                    return (index, buffer.index(after: after))
                }
                if after < buffer.endIndex || final {
                    return (index, after)
                }
                return nil
            default:
                index = buffer.index(after: index)
            }
        }
        return nil
    }

    private mutating func consume(_ line: Data) throws -> SSEEvent? {
        if line.isEmpty { return dispatchEvent() }
        guard let text = String(data: line, encoding: .utf8) else {
            throw sseFailure("cloud_sse.invalid_utf8", "SSE field was not valid UTF-8")
        }
        if text.hasPrefix(":") { return nil }
        guard assembledEventBytes <= limits.maxEventBytes - line.count else {
            throw sseFailure("cloud_sse.event_too_large", "SSE event exceeded its limit")
        }
        assembledEventBytes += line.count

        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "data":
            dataLines.append(Data(value.utf8))
        case "event":
            eventName = String(value)
        case "id":
            if !value.contains("\0") { eventID = String(value) }
        case "retry":
            if !value.isEmpty, value.allSatisfy(\.isNumber) {
                retryMilliseconds = UInt64(value)
            }
        default:
            break
        }
        return nil
    }

    private mutating func dispatchEvent() -> SSEEvent? {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
            retryMilliseconds = nil
            assembledEventBytes = 0
        }
        guard !dataLines.isEmpty else { return nil }
        var data = Data()
        for (index, line) in dataLines.enumerated() {
            if index > 0 { data.append(0x0A) }
            data.append(line)
        }
        return SSEEvent(
            event: eventName,
            id: eventID,
            retryMilliseconds: retryMilliseconds,
            data: data
        )
    }
}

private func sseFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
