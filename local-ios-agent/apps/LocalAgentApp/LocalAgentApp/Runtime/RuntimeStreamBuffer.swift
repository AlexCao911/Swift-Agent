import Foundation
import LocalAgentBridge

struct RuntimeStreamBuffer: Sendable {
    private struct BufferedDelta: Sendable {
        var event: RuntimeEventDTO
        var text: String
    }

    private var bufferedTextByMessageId: [String: BufferedDelta] = [:]
    private var messageOrder: [String] = []
    private let flushCharacterLimit: Int

    init(flushCharacterLimit: Int = 512) {
        self.flushCharacterLimit = flushCharacterLimit
    }

    var hasPendingEvents: Bool {
        !bufferedTextByMessageId.isEmpty
    }

    mutating func append(_ event: RuntimeEventDTO) -> [RuntimeEventDTO] {
        if event.kind == .assistantTextDelta {
            if let messageId = Self.payloadString("message_id", from: event.payload),
               let text = Self.payloadString("text", from: event.payload) {
                if bufferedTextByMessageId[messageId] == nil {
                    messageOrder.append(messageId)
                }
                let existingText = bufferedTextByMessageId[messageId]?.text ?? ""
                bufferedTextByMessageId[messageId] = BufferedDelta(
                    event: event,
                    text: existingText + text
                )

                if bufferedTextByMessageId[messageId]?.text.count ?? 0 >= flushCharacterLimit {
                    return flush(messageId: messageId)
                }
                return []
            }
        }

        if !bufferedTextByMessageId.isEmpty || Self.isFlushBoundary(event.kind) {
            var events = flush()
            events.append(event)
            return events
        }

        return [event]
    }

    mutating func flush() -> [RuntimeEventDTO] {
        let ids = messageOrder
        return ids.flatMap { flush(messageId: $0) }
    }

    private mutating func flush(messageId: String) -> [RuntimeEventDTO] {
        guard var buffered = bufferedTextByMessageId.removeValue(forKey: messageId) else {
            return []
        }

        messageOrder.removeAll { $0 == messageId }
        buffered.event.payload = Self.encodedPayload(messageId: messageId, text: buffered.text)
        return [buffered.event]
    }

    private static func isFlushBoundary(_ kind: RuntimeEventKindDTO) -> Bool {
        switch kind {
        case .assistantMessageCompleted,
             .runFailed,
             .runCancelled,
             .toolCallRequested,
             .toolResultMessage:
            return true
        default:
            return false
        }
    }

    private static func encodedPayload(messageId: String, text: String) -> String {
        let object = ["message_id": messageId, "text": text]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func payloadString(_ key: String, from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return object[key] as? String
    }
}
