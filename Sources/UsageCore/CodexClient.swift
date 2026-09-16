import Foundation
import Darwin

public enum CodexClientError: LocalizedError, Sendable, Equatable {
    case executableNotFound
    case launchFailed
    case signInRequired
    case signInFailed
    case unsupportedAccount
    case noUsageAvailable
    case timedOut
    case stopped
    case serverExited
    case invalidResponse
    case responseTooLarge
    case serverError(Int)
    case tooManyRequests

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex CLI was not found. Install Codex, or choose its executable in Settings."
        case .launchFailed:
            "Codex could not start. Check the executable in Settings and try again."
        case .signInRequired:
            "Sign in with your ChatGPT account to see your Codex usage."
        case .signInFailed:
            "ChatGPT sign-in did not complete. Try connecting again."
        case .unsupportedAccount:
            "Codex is using an API key or another provider. Sign in with ChatGPT to see subscription usage."
        case .noUsageAvailable:
            "Codex has not reported any usage limits for this account yet. Try refreshing later."
        case .timedOut:
            "Codex took too long to respond. Check your connection and refresh."
        case .stopped:
            "The Codex connection was stopped. Refresh to reconnect."
        case .serverExited:
            "The Codex connection closed. Refresh to reconnect."
        case .invalidResponse, .responseTooLarge:
            "Codex returned an unreadable response. Update Codex CLI and try again."
        case .serverError(let code):
            "Codex could not read your account (error \(code)). Check your sign-in in Codex, then refresh."
        case .tooManyRequests:
            "A refresh is already in progress. Try again shortly."
        }
    }
}

/// Reads subscription limits through the installed Codex app-server protocol.
/// Authentication remains entirely inside Codex; this client never reads its token files.
@MainActor
public final class CodexClient {
    private let executablePath: String?
    private let requestTimeout: Duration
    private let environment: [String: String]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var streamContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var initializeTask: Task<Void, Never>?
    private var initializationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var isInitialized = false
    private var generation: UUID?
    private var pending: [Int: PendingRequest] = [:]
    private var nextID = 0
    private var receiveBuffer = Data()
    private var signInState = SignInState.idle
    private static let maximumLineBytes = 1_048_576

    public init(executablePath: String? = nil) {
        self.executablePath = executablePath
        self.requestTimeout = .seconds(20)
        self.environment = ProcessInfo.processInfo.environment
    }

    // A short deadline keeps transport-failure tests deterministic and fast.
    init(
        executablePath: String,
        requestTimeout: Duration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executablePath = executablePath
        self.requestTimeout = requestTimeout
        self.environment = environment
    }

    isolated deinit {
        stop()
    }

    public static func locateExecutable(override: String? = nil) -> URL? {
        let manager = FileManager.default
        func executable(_ path: String) -> URL? {
            let expanded = NSString(string: path).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard expanded.hasPrefix("/"),
                  manager.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  manager.isExecutableFile(atPath: expanded) else { return nil }
            return URL(fileURLWithPath: expanded)
        }
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return executable(override.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let home = manager.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { "\($0)/codex" }
        return candidates.lazy.compactMap(executable).first
    }

    /// GUI apps started at login have a minimal PATH. npm's Codex launcher uses
    /// `/usr/bin/env node`, so locating Codex alone does not locate its interpreter.
    static func subprocessEnvironment(
        executable: URL,
        inherited: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        // Respect an existing interpreter preference, then search beside the chosen
        // launcher. Keep that bin directory even when Codex itself is a symlink.
        let candidates = (inherited["PATH"] ?? "").split(separator: ":").map(String.init) + [
            executable.deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin",
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent(".npm-global/bin").path,
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var seen = Set<String>()
        let path = candidates.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
        var result = inherited
        result["PATH"] = path.joined(separator: ":")
        return result
    }

    /// Restarting reloads the persisted sign-in instead of using an account cached
    /// by the app-server. Leave this false while a browser sign-in is in progress.
    public func fetchUsage(reloadAccount: Bool = false) async throws -> UsageSnapshot {
        try Task.checkCancellation()
        if reloadAccount { stop() }
        try await ensureRunning()
        let accountData = try await request("account/read", params: ["refreshToken": false])
        let account: AccountResponse = try decode(accountData)
        guard let identity = account.account else { throw CodexClientError.signInRequired }
        guard identity.type == "chatgpt" else { throw CodexClientError.unsupportedAccount }
        let limitsData = try await request("account/rateLimits/read", params: [:])
        return try Self.snapshot(
            from: limitsData,
            accountPlan: identity.planType,
            fetchedAt: Date(),
            accountEmail: identity.email
        )
    }

    /// Starts browser sign-in only in response to an explicit user action.
    public func startSignIn() async throws -> URL {
        signInState = .idle
        try await ensureRunning()
        let data = try await request("account/login/start", params: ["type": "chatgpt"])
        let response: LoginResponse = try decode(data)
        guard response.type == "chatgpt", !response.loginId.isEmpty,
              let url = URL(string: response.authUrl),
              url.scheme == "https", let host = url.host?.lowercased(),
              host == "openai.com" || host.hasSuffix(".openai.com")
                || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") else {
            signInState = .idle
            throw CodexClientError.invalidResponse
        }
        return url
    }

    /// Existing account data remains readable while a browser login is pending.
    /// Only completion of this specific login attempt proves the new sign-in finished.
    public func isSignInComplete() throws -> Bool {
        switch signInState {
        case .completed: true
        case .failed: throw CodexClientError.signInFailed
        case .idle, .starting, .pending: false
        }
    }

    public func stop() {
        shutDown(with: CodexClientError.stopped)
    }

    private func ensureRunning() async throws {
        try Task.checkCancellation()
        if isInitialized { return }
        if initializeTask == nil {
            try launch()
            let currentGeneration = generation
            initializeTask = Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.request("initialize", params: [
                        "clientInfo": ["name": "macaiusage", "title": "AI Usage", "version": "0.1.0"],
                    ])
                    guard self.generation == currentGeneration else { return }
                    try self.send(["method": "initialized"])
                    self.isInitialized = true
                    self.initializeTask = nil
                    let waiters = self.initializationWaiters
                    self.initializationWaiters.removeAll()
                    for waiter in waiters.values { waiter.resume() }
                } catch {
                    if self.generation == currentGeneration { self.shutDown(with: error) }
                }
            }
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                initializationWaiters[waiterID] = continuation
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.initializationWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
    }

    private func launch() throws {
        guard let executable = Self.locateExecutable(override: executablePath) else {
            throw CodexClientError.executableNotFound
        }
        let child = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let currentGeneration = UUID()
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(32)
        )
        child.executableURL = executable
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.environment = Self.subprocessEnvironment(executable: executable, inherited: environment)
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        // Never retain or display CLI diagnostic output, which may contain account details.
        child.standardError = FileHandle.nullDevice
        let readHandle = stdoutPipe.fileHandleForReading
        let maximumLineBytes = Self.maximumLineBytes
        readHandle.readabilityHandler = { handle in
            // read(upToCount:) can wait for a full count on a pipe. availableData
            // returns the currently readable chunk without waiting for another reply.
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else if data.count > maximumLineBytes {
                handle.readabilityHandler = nil
                continuation.finish(throwing: CodexClientError.responseTooLarge)
            } else if case .dropped = continuation.yield(data) {
                handle.readabilityHandler = nil
                continuation.finish(throwing: CodexClientError.responseTooLarge)
            }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                // Give the stdout reader time to consume a final buffered response before EOF.
                try? await Task.sleep(for: .milliseconds(100))
                guard self?.generation == currentGeneration else { return }
                self?.shutDown(with: CodexClientError.serverExited)
            }
        }
        generation = currentGeneration
        process = child
        input = stdinPipe.fileHandleForWriting
        output = readHandle
        streamContinuation = continuation
        receiveBuffer.removeAll(keepingCapacity: true)
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try child.run() } catch {
            shutDown(with: CodexClientError.launchFailed)
            throw CodexClientError.launchFailed
        }
        readerTask = Task { [weak self] in
            do {
                for try await data in stream {
                    guard self?.generation == currentGeneration else { return }
                    try self?.receive(data)
                }
                guard self?.generation == currentGeneration else { return }
                self?.shutDown(with: CodexClientError.serverExited)
            } catch {
                guard self?.generation == currentGeneration else { return }
                self?.shutDown(with: error)
            }
        }
    }

    private func request(_ method: String, params: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        guard process?.isRunning == true else { throw CodexClientError.serverExited }
        guard pending.count < 32 else { throw CodexClientError.tooManyRequests }
        nextID += 1
        let id = nextID
        if method == "account/login/start" { signInState = .starting(requestID: id) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeout = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    guard let self, self.pending[id] != nil else { return }
                    self.shutDown(with: CodexClientError.timedOut)
                }
                pending[id] = PendingRequest(continuation: continuation, timeout: timeout)
                do { try send(["id": id, "method": method, "params": params]) }
                catch { shutDown(with: CodexClientError.serverExited) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.complete(id, result: .failure(CancellationError()))
            }
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard let input else { throw CodexClientError.stopped }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) throws {
        receiveBuffer.append(data)
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer[..<newline]
            guard line.count <= Self.maximumLineBytes else { throw CodexClientError.responseTooLarge }
            let response: [String: Any]
            do {
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexClientError.invalidResponse
                }
                response = object
            } catch { throw CodexClientError.invalidResponse }
            receiveBuffer.removeSubrange(...newline)
            // Server notifications carry no request ID. Never expose their error text,
            // which can include private account or authentication details.
            guard let id = response["id"] as? Int else {
                receiveSignInNotification(response)
                continue
            }
            guard pending[id] != nil else { continue }
            if let error = response["error"] as? [String: Any] {
                complete(id, result: .failure(CodexClientError.serverError(error["code"] as? Int ?? -1)))
            } else if let result = response["result"] {
                let body = try JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed)
                if case .starting(let requestID) = signInState, requestID == id {
                    // Record the login ID before resuming the caller: the next line in
                    // this same stdout chunk may already be its completion notification.
                    if let login = try? JSONDecoder().decode(LoginResponse.self, from: body),
                       login.type == "chatgpt", !login.loginId.isEmpty {
                        signInState = .pending(loginID: login.loginId)
                    } else {
                        signInState = .idle
                    }
                }
                complete(id, result: .success(body))
            } else {
                complete(id, result: .failure(CodexClientError.invalidResponse))
            }
        }
        guard receiveBuffer.count <= Self.maximumLineBytes else { throw CodexClientError.responseTooLarge }
    }

    private func receiveSignInNotification(_ response: [String: Any]) {
        guard case .pending(let loginID) = signInState,
              response["method"] as? String == "account/login/completed",
              let params = response["params"] as? [String: Any],
              params["loginId"] as? String == loginID,
              let succeeded = params["success"] as? Bool else { return }
        signInState = succeeded ? .completed : .failed
    }

    private func complete(_ id: Int, result: Result<Data, any Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func shutDown(with error: any Error) {
        signInState = .idle
        generation = nil
        isInitialized = false
        initializeTask?.cancel()
        initializeTask = nil
        readerTask?.cancel()
        readerTask = nil
        output?.readabilityHandler = nil
        streamContinuation?.finish()
        streamContinuation = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        let child = process
        process = nil
        child?.terminationHandler = nil
        if let child, child.isRunning {
            child.terminate()
            Task {
                try? await Task.sleep(for: .seconds(2))
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        let requests = pending
        pending.removeAll()
        let waiters = initializationWaiters
        initializationWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(throwing: error) }
        for request in requests.values {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw CodexClientError.invalidResponse }
    }

    static func snapshot(
        from data: Data,
        accountPlan: String?,
        fetchedAt: Date,
        accountEmail: String? = nil
    ) throws -> UsageSnapshot {
        let response: LimitsResponse
        do { response = try JSONDecoder().decode(LimitsResponse.self, from: data) }
        catch { throw CodexClientError.invalidResponse }
        // Never substitute model-specific or reserve buckets for the main Codex allowance.
        let limit = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
        guard limit.limitId == nil || limit.limitId == "codex" else { throw CodexClientError.noUsageAvailable }
        let windows = [("primary", limit.primary), ("secondary", limit.secondary)].compactMap { id, value in
            value.map {
                UsageWindow(
                    id: id,
                    title: windowTitle(duration: $0.windowDurationMins, fallback: id),
                    usedPercent: min(100, max(0, $0.usedPercent)),
                    durationMinutes: $0.windowDurationMins,
                    resetsAt: $0.resetsAt.map(Date.init(timeIntervalSince1970:))
                )
            }
        }
        guard !windows.isEmpty else { throw CodexClientError.noUsageAvailable }
        let plan = limit.planType ?? accountPlan
        return UsageSnapshot(
            planName: plan.map { $0.replacingOccurrences(of: "_", with: " ").capitalized },
            windows: windows,
            fetchedAt: fetchedAt,
            accountEmail: accountEmail
        )
    }

    private static func windowTitle(duration: Int?, fallback: String) -> String {
        switch duration {
        case 300: "Session"
        case 10_080: "Weekly"
        case 1_440: "Daily"
        case .some(let minutes) where minutes > 0 && minutes.isMultiple(of: 1_440): "\(minutes / 1_440)-day window"
        case .some(let minutes) where minutes > 0 && minutes.isMultiple(of: 60): "\(minutes / 60)-hour window"
        case .some(let minutes) where minutes > 0: "\(minutes)-minute window"
        default: fallback == "primary" ? "Primary limit" : "Secondary limit"
        }
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, any Error>
        let timeout: Task<Void, Never>
    }

    private struct AccountResponse: Decodable {
        let account: Identity?
        struct Identity: Decodable {
            let type: String
            let planType: String?
            let email: String?
        }
    }

    private struct LoginResponse: Decodable {
        let type: String
        let authUrl: String
        let loginId: String
    }

    private enum SignInState {
        case idle
        case starting(requestID: Int)
        case pending(loginID: String)
        case completed
        case failed
    }

    private struct LimitsResponse: Decodable {
        let rateLimits: Limit
        let rateLimitsByLimitId: [String: Limit]?
        struct Limit: Decodable {
            let limitId: String?
            let planType: String?
            let primary: Window?
            let secondary: Window?
        }
        struct Window: Decodable {
            let usedPercent: Double
            let windowDurationMins: Int?
            let resetsAt: Double?
        }
    }
}
