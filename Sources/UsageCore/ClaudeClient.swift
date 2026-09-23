import Foundation
import Darwin

public enum ClaudeClientError: LocalizedError, Sendable, Equatable {
    case executableNotFound, unavailable, invalidResponse, timedOut, stopped, serverExited

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Claude Code was not found. Install a current version, or choose its executable in Settings."
        case .unavailable:
            "Claude subscription usage is unavailable. Sign in with your subscription in Claude Code, then refresh. API-key usage is not included."
        case .invalidResponse:
            "Claude Code could not report usage. Update Claude Code to 2.1.280 or later, then refresh."
        case .timedOut:
            "Claude Code took too long to respond. Check your connection and refresh."
        case .stopped:
            "The Claude connection was stopped. Refresh to reconnect."
        case .serverExited:
            "Claude Code closed before reporting usage. Update Claude Code and check its sign-in, then refresh."
        }
    }
}

/// Reads Claude Code's experimental get_usage control request. No model prompt,
/// credential-file reads, transcript scans, or direct authenticated HTTP requests.
@MainActor
public final class ClaudeClient {
    private let executablePath: String?
    private let timeout: Duration
    private var task: Task<UsageSnapshot, any Error>?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?

    public init(executablePath: String? = nil, timeout: Duration = .seconds(30)) {
        self.executablePath = executablePath
        self.timeout = timeout
    }

    isolated deinit { stop() }

    public static func locateExecutable(override: String? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CodexClient.locateExecutable(override: override)
        }
        // Conductor can carry a newer Claude than the separately installed CLI.
        let managed = home.appendingPathComponent("Library/Application Support/com.conductor.app/agent-binaries/claude")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: managed.path)) ?? [])
            .filter { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        let candidates = versions.map { managed.appendingPathComponent($0).appendingPathComponent("claude").path } + [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            home.appendingPathComponent(".npm-global/bin/claude").path,
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { "\($0)/claude" }
        return candidates.lazy.compactMap { CodexClient.locateExecutable(override: $0) }.first
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        try Task.checkCancellation()
        if let task { return try await task.value }
        let operation = Task { try await self.readUsage() }
        task = operation
        defer { task = nil }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    public func stop() {
        task?.cancel()
        continuation?.finish(throwing: ClaudeClientError.stopped)
        closeProcess()
    }

    private func readUsage() async throws -> UsageSnapshot {
        try Task.checkCancellation()
        guard let executable = Self.locateExecutable(override: executablePath) else { throw ClaudeClientError.executableNotFound }
        let child = Process()
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        let (stream, streamContinuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        child.executableURL = executable
        child.arguments = ["-p", "--safe-mode", "--no-session-persistence", "--input-format", "stream-json",
                           "--output-format", "stream-json", "--verbose", "--tools", "",
                           "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]
        child.environment = CodexClient.subprocessEnvironment(executable: executable, inherited: ProcessInfo.processInfo.environment)
        child.currentDirectoryURL = FileManager.default.temporaryDirectory
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice
        process = child
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        continuation = streamContinuation
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                streamContinuation.finish()
            } else if data.count > 1_048_576 {
                streamContinuation.finish(throwing: ClaudeClientError.invalidResponse)
            } else if case .dropped = streamContinuation.yield(data) {
                streamContinuation.finish(throwing: ClaudeClientError.invalidResponse)
            }
        }
        defer { closeProcess() }
        do { try child.run() } catch { throw ClaudeClientError.serverExited }
        let deadline = Task { [timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            streamContinuation.finish(throwing: ClaudeClientError.timedOut)
        }
        defer { deadline.cancel() }
        try send(id: "initialize", request: ["subtype": "initialize", "hooks": [:], "sdkMcpServers": []])
        var initialized = false
        var buffer = Data()
        for try await chunk in stream {
            try Task.checkCancellation()
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]
                guard line.count <= 1_048_576,
                      let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw ClaudeClientError.invalidResponse
                }
                buffer.removeSubrange(...newline)
                guard message["type"] as? String == "control_response",
                      let response = message["response"] as? [String: Any],
                      let id = response["request_id"] as? String,
                      id == (initialized ? "usage" : "initialize") else { continue }
                guard response["subtype"] as? String == "success" else { throw ClaudeClientError.invalidResponse }
                if !initialized {
                    initialized = true
                    try send(id: "usage", request: ["subtype": "get_usage", "skip_behaviors": true])
                } else {
                    guard let body = response["response"] as? [String: Any] else { throw ClaudeClientError.invalidResponse }
                    return try Self.snapshot(from: JSONSerialization.data(withJSONObject: body))
                }
            }
            guard buffer.count <= 1_048_576 else { throw ClaudeClientError.invalidResponse }
        }
        try Task.checkCancellation()
        throw ClaudeClientError.serverExited
    }

    private func send(id: String, request: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id, "request": request])
        data.append(10)
        try input?.write(contentsOf: data)
    }

    private func closeProcess() {
        output?.readabilityHandler = nil
        continuation?.finish()
        continuation = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        let child = process
        process = nil
        if let child, child.isRunning {
            child.terminate()
            Task {
                try? await Task.sleep(for: .seconds(2))
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }

    static func snapshot(from data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let response: UsageResponse
        do { response = try JSONDecoder().decode(UsageResponse.self, from: data) }
        catch { throw ClaudeClientError.invalidResponse }
        guard response.rate_limits_available, let limits = response.rate_limits else { throw ClaudeClientError.unavailable }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func window(_ value: UsageResponse.Window?, id: String, title: String, duration: Int) throws -> UsageWindow? {
            guard let value, let percent = value.utilization else { return nil }
            guard percent.isFinite, (0...100).contains(percent) else { throw ClaudeClientError.invalidResponse }
            var reset: Date?
            if let raw = value.resets_at {
                reset = fractional.date(from: raw) ?? plain.date(from: raw)
                guard reset != nil else { throw ClaudeClientError.invalidResponse }
            }
            return UsageWindow(id: id, title: title, usedPercent: percent, durationMinutes: duration, resetsAt: reset)
        }
        var windows = try [
            window(limits.five_hour, id: "session", title: "Session", duration: 300),
            window(limits.seven_day, id: "weekly", title: "Weekly", duration: 10_080),
        ].compactMap { $0 }
        for (index, scoped) in (limits.model_scoped ?? []).enumerated() {
            if let value = try window(scoped, id: "model-\(index)", title: "Weekly · \(scoped.display_name ?? "Model")", duration: 10_080) {
                windows.append(value)
            }
        }
        guard !windows.isEmpty else { throw ClaudeClientError.unavailable }
        return UsageSnapshot(planName: response.subscription_type?.capitalized, windows: windows, fetchedAt: fetchedAt)
    }

    private struct UsageResponse: Decodable {
        let subscription_type: String?
        let rate_limits_available: Bool
        let rate_limits: Limits?
        struct Limits: Decodable {
            let five_hour: Window?
            let seven_day: Window?
            let model_scoped: [Window]?
        }
        struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?
            let display_name: String?
        }
    }
}
