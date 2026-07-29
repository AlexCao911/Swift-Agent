import Foundation
import LocalAgentLLMContracts

protocol OpenMinisBrowserRunning: Sendable {
    func execute(runID: String, argumentsJSON: String) async -> OpenMinisBrowserExecutionResult
    func finish(runID: String) async
}

struct OpenMinisBrowserExecutionResult: Sendable {
    let value: CanonicalJSONValue
    let isError: Bool
}

@MainActor
final class OpenMinisBrowserRuntime: OpenMinisBrowserRunning, @unchecked Sendable {
    private var poolsByRunID: [String: BrowserTabPool] = [:]

    func execute(
        runID: String,
        argumentsJSON: String
    ) async -> OpenMinisBrowserExecutionResult {
        guard let input = BrowserActionInput.parse(from: argumentsJSON) else {
            return result(
                text: "Invalid browser_use input. A supported action is required.",
                success: false
            )
        }

        let pool = poolsByRunID[runID] ?? {
            let value = BrowserTabPool()
            value.sessionId = runID
            poolsByRunID[runID] = value
            return value
        }()
        do {
            let output = try await pool.execute(action: input)
            var entries = [
                CanonicalJSONObjectEntry(name: "text", value: .string(output.text)),
                CanonicalJSONObjectEntry(name: "success", value: .bool(output.success)),
            ]
            if let pageURL = output.pageURL {
                entries.append(
                    CanonicalJSONObjectEntry(name: "page_url", value: .string(pageURL))
                )
            }
            if let image = output.base64Image {
                entries.append(
                    CanonicalJSONObjectEntry(name: "image_base64", value: .string(image))
                )
            }
            return OpenMinisBrowserExecutionResult(
                value: try! .object(entries: entries),
                isError: output.success == false,
            )
        } catch is CancellationError {
            return result(text: "Browser action cancelled.", success: false)
        } catch {
            return result(text: error.localizedDescription, success: false)
        }
    }

    func finish(runID: String) {
        poolsByRunID.removeValue(forKey: runID)
    }

    private func result(text: String, success: Bool) -> OpenMinisBrowserExecutionResult {
        OpenMinisBrowserExecutionResult(
            value: .string(text),
            isError: success == false
        )
    }
}
