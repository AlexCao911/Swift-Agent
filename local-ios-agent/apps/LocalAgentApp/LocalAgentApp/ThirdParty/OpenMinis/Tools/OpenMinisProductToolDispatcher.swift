import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts

final class OpenMinisProductToolDispatcher: OpenMinisToolDispatching, @unchecked Sendable {
    private let ish: any OpenMinisISHRunning
    private let browser: any OpenMinisBrowserRunning
    private let files: ToolFileResolver
    private let nativeTools: (any HostToolDriving)?

    init(
        ish: any OpenMinisISHRunning = OpenMinisISHRuntime.shared,
        browser: any OpenMinisBrowserRunning = OpenMinisBrowserRuntime(),
        files: ToolFileResolver = LocalAgentToolMounts.makeDefaultResolver(),
        nativeTools: (any HostToolDriving)? = nil
    ) {
        self.ish = ish
        self.browser = browser
        self.files = files
        self.nativeTools = nativeTools
    }

    func execute(
        _ call: HostToolCall,
        context: OpenMinisToolExecutionContext
    ) async -> HostToolResult {
        guard let arguments = arguments(call.argumentsJSON) else {
            return error(call, "Tool arguments must be a JSON object.")
        }

        switch call.toolName {
        case "shell_execute":
            return await executeShell(call, arguments: arguments, context: context)
        case "file_read":
            return await executeFileRead(call, arguments: arguments, context: context)
        case "file_write":
            return await executeFileWrite(call, arguments: arguments, context: context)
        case "file_edit":
            return await executeFileEdit(call, arguments: arguments, context: context)
        case "browser_use":
            let output = await browser.execute(
                runID: context.runID,
                argumentsJSON: call.argumentsJSON
            )
            return result(
                call,
                value: output.value,
                isError: output.isError,
                dataClasses: [EgressDataClass.text.rawValue],
                sensitivity: DataSensitivity.private.rawValue
            )
        default:
            return await executeNative(call, context: context)
        }
    }

    func cancel(processID: Int32) async {
        guard processID >= 0 else { return }
        ISHShellExecutor.killProcessGroup(processID)
    }

    func finish(runID: String) async {
        await browser.finish(runID: runID)
    }

    private func executeNative(
        _ call: HostToolCall,
        context: OpenMinisToolExecutionContext
    ) async -> HostToolResult {
        guard let nativeTools,
              let output = await nativeTools.execute(
                  ToolExecutionRequestDTO(
                      runId: context.runID,
                      sessionId: context.runID,
                      toolCallEntryId: "\(context.batchID):\(call.callID)",
                      toolCallId: call.callID,
                      toolName: call.toolName,
                      argumentsJson: call.argumentsJSON
                  ),
                  continuationIndex: 0
              ) else {
            return error(call, "Unsupported tool '\(call.toolName)'.")
        }
        return result(
            call,
            value: .string(
                ToolResultCredentialRedactor.redact(output.modelText)
            ),
            isError: output.isError,
            dataClasses: [EgressDataClass.unknownData.rawValue],
            sensitivity: dataSensitivity(output.sensitivity)
        )
    }

    private func executeShell(
        _ call: HostToolCall,
        arguments: [String: Any],
        context: OpenMinisToolExecutionContext
    ) async -> HostToolResult {
        guard let command = nonemptyString(arguments["command"]) else {
            return error(call, "Missing required 'command' parameter.")
        }

        let delay = boundedInteger(arguments["delay"], default: 0, range: 0...86_400)
        if delay > 0 {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return self.error(call, "Shell command cancelled before execution.")
            }
        }
        guard !Task.isCancelled else {
            return error(call, "Shell command cancelled before execution.")
        }

        let timeout = boundedInteger(arguments["timeout"], default: 120, range: 1...600)
        let commandResult = await executeISH(
            executable: "/bin/sh",
            arguments: ["-c", command],
            stdin: nil,
            timeoutSeconds: timeout,
            onProcessStarted: context.onProcessStarted
        )
        let output = [commandResult.stdout, commandResult.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: commandResult.stdout.isEmpty ? "" : "\n")
        return result(
            call,
            value: .string(ToolResultCredentialRedactor.redact(output)),
            isError: commandResult.exitCode != 0 || commandResult.wasCancelled,
            dataClasses: [EgressDataClass.unknownData.rawValue],
            sensitivity: DataSensitivity.unknown.rawValue
        )
    }

    private func executeFileRead(
        _ call: HostToolCall,
        arguments: [String: Any],
        context: OpenMinisToolExecutionContext
    ) async -> HostToolResult {
        guard let path = nonemptyString(arguments["path"]) else {
            return error(call, "Missing required 'path' parameter.")
        }
        do {
            let resolved = try files.resolve(path, access: .read)
            let text = try await readText(resolved, context: context)
            let offset = boundedInteger(arguments["offset"], default: 0, range: 0...Int.max)
            let requestedLines = boundedInteger(arguments["lines"], default: 0, range: 0...100_000)
            let maxLength = boundedInteger(
                arguments["max_length"],
                default: 100_000,
                range: 1...1_000_000
            )
            var lines = text.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).map(String.init)
            if offset < lines.count {
                lines = Array(lines.dropFirst(offset))
            } else {
                lines = []
            }
            if requestedLines > 0 {
                lines = Array(lines.prefix(requestedLines))
            }
            var output = lines.joined(separator: "\n")
            if output.count > maxLength {
                output = String(output.prefix(maxLength)) + "\n…[truncated]"
            }
            return result(
                call,
                value: .string(ToolResultCredentialRedactor.redact(output)),
                dataClasses: [EgressDataClass.files.rawValue],
                sensitivity: DataSensitivity.private.rawValue
            )
        } catch {
            return self.error(call, fileErrorMessage(error))
        }
    }

    private func executeFileWrite(
        _ call: HostToolCall,
        arguments: [String: Any],
        context: OpenMinisToolExecutionContext
    ) async -> HostToolResult {
        guard let path = nonemptyString(arguments["path"]),
              let content = arguments["content"] as? String else {
            return error(call, "Missing required 'path' or 'content' parameter.")
        }
        do {
            let resolved = try files.resolve(path, access: .write)
            try await writeText(
                content,
                to: resolved,
                append: arguments["append"] as? Bool ?? false,
                createDirectories: arguments["create_dirs"] as? Bool ?? true,
                context: context
            )
            return result(
                call,
                value: .string("Wrote \(content.utf8.count) bytes to \(path)."),
                dataClasses: [EgressDataClass.files.rawValue],
                sensitivity: DataSensitivity.private.rawValue
            )
        } catch {
            return self.error(call, fileErrorMessage(error))
        }
    }

    private func executeFileEdit(
        _ call: HostToolCall,
        arguments: [String: Any],
        context: OpenMinisToolExecutionContext
    ) async -> HostToolResult {
        guard let path = nonemptyString(arguments["path"]),
              let old = nonemptyString(arguments["old_string"]),
              let new = arguments["new_string"] as? String else {
            return error(
                call,
                "Missing required 'path', non-empty 'old_string', or 'new_string' parameter."
            )
        }
        do {
            let readable = try files.resolve(path, access: .read)
            let writable = try files.resolve(path, access: .write)
            var text = try await readText(readable, context: context)
            guard text.contains(old) else {
                return error(call, "old_string was not found in \(path).")
            }
            let replaceAll = arguments["replace_all"] as? Bool ?? false
            let replacements: Int
            if replaceAll {
                replacements = text.components(separatedBy: old).count - 1
                text = text.replacingOccurrences(of: old, with: new)
            } else {
                replacements = 1
                let range = text.range(of: old)!
                text.replaceSubrange(range, with: new)
            }
            try await writeText(
                text,
                to: writable,
                append: false,
                createDirectories: false,
                context: context
            )
            return result(
                call,
                value: .string("Updated \(path) (\(replacements) replacement(s))."),
                dataClasses: [EgressDataClass.files.rawValue],
                sensitivity: DataSensitivity.private.rawValue
            )
        } catch {
            return self.error(call, fileErrorMessage(error))
        }
    }

    private func readText(
        _ file: ResolvedToolFile,
        context: OpenMinisToolExecutionContext
    ) async throws -> String {
        switch file.backend {
        case .hostMount(_, let url):
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 2_000_000 else {
                throw ProductToolError.fileTooLarge
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw ProductToolError.notUTF8
            }
            return text
        case .guestRootfs(let linuxPath):
            let output = await executeISH(
                executable: "/bin/cat",
                arguments: [linuxPath],
                stdin: nil,
                timeoutSeconds: 60,
                onProcessStarted: context.onProcessStarted
            )
            guard output.exitCode == 0 else {
                throw ProductToolError.guestFailure(output.stderr)
            }
            return output.stdout
        }
    }

    private func writeText(
        _ text: String,
        to file: ResolvedToolFile,
        append: Bool,
        createDirectories: Bool,
        context: OpenMinisToolExecutionContext
    ) async throws {
        switch file.backend {
        case .hostMount(_, let url):
            if createDirectories {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            let data = Data(text.utf8)
            if append, FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        case .guestRootfs(let linuxPath):
            if createDirectories {
                let parent = (linuxPath as NSString).deletingLastPathComponent
                let mkdir = await executeISH(
                    executable: "/bin/mkdir",
                    arguments: ["-p", parent],
                    stdin: nil,
                    timeoutSeconds: 30,
                    onProcessStarted: context.onProcessStarted
                )
                guard mkdir.exitCode == 0 else {
                    throw ProductToolError.guestFailure(mkdir.stderr)
                }
            }
            let script = append ? #"cat >> "$1""# : #"cat > "$1""#
            let output = await executeISH(
                executable: "/bin/sh",
                arguments: ["-c", script, "localagent-file-write", linuxPath],
                stdin: Data(text.utf8),
                timeoutSeconds: 60,
                onProcessStarted: context.onProcessStarted
            )
            guard output.exitCode == 0 else {
                throw ProductToolError.guestFailure(output.stderr)
            }
        }
    }

    private func executeISH(
        executable: String,
        arguments: [String],
        stdin: Data?,
        timeoutSeconds: Int,
        onProcessStarted: @escaping @Sendable (Int32) async -> Void
    ) async -> ISHCommandResult {
        await withTaskGroup(of: TimedISHResult.self) { group in
            group.addTask { [ish] in
                .command(await ish.execute(
                    executable: executable,
                    arguments: arguments,
                    stdin: stdin,
                    onProcessStarted: onProcessStarted
                ))
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    return .timeout
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            switch first {
            case .command(let result):
                return result
            case .timeout:
                return ISHCommandResult(
                    pid: -1,
                    exitCode: 124,
                    stdout: "",
                    stderr: "Command timed out after \(timeoutSeconds) seconds.",
                    duration: TimeInterval(timeoutSeconds),
                    wasCancelled: true
                )
            case .cancelled:
                return ISHCommandResult(
                    pid: -1,
                    exitCode: 130,
                    stdout: "",
                    stderr: "Command cancelled.",
                    duration: 0,
                    wasCancelled: true
                )
            }
        }
    }

    private func arguments(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            return nil
        }
        return object
    }

    private func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private func boundedInteger(
        _ value: Any?,
        default defaultValue: Int,
        range: ClosedRange<Int>
    ) -> Int {
        let candidate = value as? Int ?? (value as? NSNumber)?.intValue ?? defaultValue
        return min(max(candidate, range.lowerBound), range.upperBound)
    }

    private func result(
        _ call: HostToolCall,
        value: CanonicalJSONValue,
        isError: Bool = false,
        dataClasses: [String],
        sensitivity: String
    ) -> HostToolResult {
        HostToolResult(
            callID: call.callID,
            toolName: call.toolName,
            result: value,
            isError: isError,
            dataClasses: dataClasses,
            highestSensitivity: sensitivity
        )
    }

    private func error(_ call: HostToolCall, _ message: String) -> HostToolResult {
        result(
            call,
            value: .string(message),
            isError: true,
            dataClasses: [EgressDataClass.unknownData.rawValue],
            sensitivity: DataSensitivity.unknown.rawValue
        )
    }

    private func dataSensitivity(_ value: SensitivityDTO) -> String {
        switch value {
        case .public:
            DataSensitivity.routine.rawValue
        case .private:
            DataSensitivity.private.rawValue
        case .secret:
            DataSensitivity.highlySensitive.rawValue
        default:
            DataSensitivity.unknown.rawValue
        }
    }

    private func fileErrorMessage(_ error: Error) -> String {
        if let error = error as? ToolFileResolverError {
            return "File access rejected: \(error.code)."
        }
        if let error = error as? ProductToolError {
            return error.description
        }
        return "File operation failed: \(error.localizedDescription)"
    }
}

private enum TimedISHResult: Sendable {
    case command(ISHCommandResult)
    case timeout
    case cancelled
}

private enum ProductToolError: Error {
    case fileTooLarge
    case notUTF8
    case guestFailure(String)

    var description: String {
        switch self {
        case .fileTooLarge:
            "File exceeds the 2 MB direct-read limit."
        case .notUTF8:
            "File is not valid UTF-8 text."
        case .guestFailure(let message):
            message.isEmpty ? "Linux file operation failed." : message
        }
    }
}

enum ToolResultCredentialRedactor {
    private static let expressions: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s"'\\]+"#
        ),
        try! NSRegularExpression(
            pattern: #"(?i)((?:api[_-]?key|oauth[_-]?token|access[_-]?token)\s*[:=]\s*)[^\s"'\\]+"#
        ),
        try! NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9_-]{12,}\b"#),
    ]

    static func redact(_ value: String) -> String {
        var output = value
        for (index, expression) in expressions.enumerated() {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            let template = index < 2 ? "$1[REDACTED]" : "[REDACTED]"
            output = expression.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: template
            )
        }
        return output
    }
}
