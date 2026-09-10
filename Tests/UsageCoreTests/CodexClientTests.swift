import Foundation
import Testing
@testable import UsageCore

@MainActor
struct CodexClientTests {
    @Test func readsRealProtocolWithFragmentedResponsesAndConcurrentCallers() async throws {
        let server = try FixtureServer(mode: "success")
        defer { server.remove() }
        let client = CodexClient(executablePath: server.executable.path)
        defer { client.stop() }

        async let first = client.fetchUsage()
        async let second = client.fetchUsage()
        let snapshots = try await [first, second]

        for snapshot in snapshots {
            #expect(snapshot.planName == "Pro")
            #expect(snapshot.windows.count == 1)
            let window = try #require(snapshot.windows.first)
            #expect(window.id == "primary")
            #expect(window.title == "Weekly")
            #expect(window.remainingPercent == 51)
            #expect(window.resetsAt == Date(timeIntervalSince1970: 1_789_440_455))
        }
        let methods = try server.methods()
        #expect(methods.filter { $0 == "initialize" }.count == 1)
        #expect(methods.filter { $0 == "initialized" }.count == 1)
        #expect(methods.filter { $0 == "account/read" }.count == 2)
        #expect(methods.filter { $0 == "account/rateLimits/read" }.count == 2)
        #expect(!methods.contains("account/login/start"))
    }

    @Test(arguments: ["signedOut", "apiKey"])
    func explainsAccountStateWithoutRequestingUsage(mode: String) async throws {
        let server = try FixtureServer(mode: mode)
        defer { server.remove() }
        let client = CodexClient(executablePath: server.executable.path)
        defer { client.stop() }
        await #expect(throws: mode == "signedOut" ? CodexClientError.signInRequired : .unsupportedAccount) {
            try await client.fetchUsage()
        }
        #expect(!(try server.methods()).contains("account/rateLimits/read"))
    }

    @Test func timesOutAndCanStartANewConnection() async throws {
        let server = try FixtureServer(mode: "timeout")
        defer { server.remove() }
        let client = CodexClient(executablePath: server.executable.path, requestTimeout: .milliseconds(500))
        defer { client.stop() }
        await #expect(throws: CodexClientError.timedOut) { try await client.fetchUsage() }
        try server.setMode("success")
        let snapshot = try await client.fetchUsage()
        #expect(snapshot.windows.first?.remainingPercent == 51)
    }

    @Test(arguments: ["exit", "malformed", "oversized", "remoteError"])
    func failsPromptlyWhenServerCannotRespond(mode: String) async throws {
        let server = try FixtureServer(mode: mode)
        defer { server.remove() }
        let client = CodexClient(executablePath: server.executable.path, requestTimeout: .seconds(3))
        defer { client.stop() }
        let expected: CodexClientError = switch mode {
        case "exit": .serverExited
        case "malformed": .invalidResponse
        case "oversized": .responseTooLarge
        default: .serverError(-32001)
        }
        await #expect(throws: expected) { try await client.fetchUsage() }
    }

    @Test func stoppingResumesPendingRequestsAndAllowsReconnect() async throws {
        let server = try FixtureServer(mode: "timeout")
        defer { server.remove() }
        let client = CodexClient(executablePath: server.executable.path)
        defer { client.stop() }
        let fetch = Task { try await client.fetchUsage() }
        try await server.waitForMethod("account/read")
        client.stop()
        await #expect(throws: CodexClientError.stopped) { try await fetch.value }
        try server.setMode("success")
        let snapshot = try await client.fetchUsage()
        #expect(snapshot.windows.first?.title == "Weekly")
    }

    @Test func cancellingARequestDoesNotBreakTheConnection() async throws {
        let server = try FixtureServer(mode: "timeout")
        defer { server.remove() }
        let client = CodexClient(executablePath: server.executable.path)
        defer { client.stop() }
        let fetch = Task { try await client.fetchUsage() }
        try await server.waitForMethod("account/read")
        fetch.cancel()
        await #expect(throws: CancellationError.self) { try await fetch.value }
        try server.setMode("success")
        let snapshot = try await client.fetchUsage()
        #expect(snapshot.windows.count == 1)
        #expect(try server.methods().filter { $0 == "initialize" }.count == 1)
    }

    @Test func startsOnlyTheExplicitBrowserLoginFlow() async throws {
        let server = try FixtureServer(mode: "success")
        defer { server.remove() }
        let client = CodexClient(executablePath: server.executable.path)
        defer { client.stop() }
        let url = try await client.startSignIn()
        #expect(url.absoluteString == "https://auth.openai.com/test-only")
        #expect(try server.methods() == ["initialize", "initialized", "account/login/start"])
    }

    @Test(arguments: [false, true])
    func launchesEnvShebangFromLoginEnvironmentAndReconnects(signInFirst: Bool) async throws {
        let server = try FixtureServer(mode: "minimalEnvironment", usesEnvInterpreter: true)
        defer { server.remove() }
        let client = CodexClient(
            executablePath: server.executable.path,
            requestTimeout: .seconds(3),
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": "/test-only/home with spaces",
                "CODEX_HOME": "/test-only/custom codex home",
                "OPENAI_API_KEY": "fixture-only-value",
            ]
        )
        defer { client.stop() }

        if signInFirst {
            #expect(try await client.startSignIn().absoluteString == "https://auth.openai.com/test-only")
        } else {
            #expect(try await client.fetchUsage().windows.first?.remainingPercent == 51)
        }
        client.stop()
        #expect(try await client.fetchUsage().planName == "Pro")

        let methods = try server.methods()
        #expect(methods.filter { $0 == "initialize" }.count == 2)
        #expect(methods.filter { $0 == "account/login/start" }.count == (signInFirst ? 1 : 0))
    }

    @Test func childPathPreservesInterpreterPreferenceAndAuthenticationEnvironment() {
        let inherited = [
            "PATH": "/preferred node/bin:/usr/bin::relative/bin:/usr/bin:/usr/local/bin",
            "HOME": "/custom home",
            "CODEX_HOME": "/custom codex home",
            "OPENAI_API_KEY": "fixture-only-value",
            "OTHER_SETTING": "unchanged",
        ]
        let environment = CodexClient.subprocessEnvironment(
            executable: URL(fileURLWithPath: "/chosen bin/codex"),
            inherited: inherited,
            homeDirectory: URL(fileURLWithPath: "/custom home")
        )
        #expect(environment["PATH"]?.split(separator: ":").map(String.init) == [
            "/preferred node/bin", "/usr/bin", "/usr/local/bin", "/chosen bin",
            "/opt/homebrew/bin", "/custom home/.local/bin", "/custom home/.npm-global/bin",
            "/bin", "/usr/sbin", "/sbin",
        ])
        #expect(environment.filter { $0.key != "PATH" } == inherited.filter { $0.key != "PATH" })
    }

    @Test func childEnvironmentProvidesSystemToolsWhenPathIsMissing() {
        let environment = CodexClient.subprocessEnvironment(
            executable: URL(fileURLWithPath: "/usr/local/bin/codex"),
            inherited: [:],
            homeDirectory: URL(fileURLWithPath: "/test-only/home")
        )
        #expect(environment == ["PATH": "/usr/local/bin:/opt/homebrew/bin:/test-only/home/.local/bin:/test-only/home/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    @Test func cancellingDuringInitializationPreservesOtherCallers() async throws {
        let server = try FixtureServer(mode: "slowInitialize")
        defer { server.remove() }
        let client = CodexClient(executablePath: server.executable.path)
        defer { client.stop() }
        let cancelledFetch = Task { try await client.fetchUsage() }
        let survivingFetch = Task { try await client.fetchUsage() }
        try await server.waitForMethod("initialize")
        cancelledFetch.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledFetch.value }
        #expect(try await survivingFetch.value.windows.first?.remainingPercent == 51)
        #expect(try server.methods().filter { $0 == "initialize" }.count == 1)
    }

    @Test func rejectsMissingExecutableWithoutLaunchingAnything() async throws {
        let client = CodexClient(executablePath: "/does-not-exist/quota-bar-test")
        await #expect(throws: CodexClientError.executableNotFound) { try await client.fetchUsage() }
        #expect(CodexClient.locateExecutable(override: "/tmp") == nil)
    }

    @Test func decodesLegacyLimitsWithMissingResetAndClampsPercentages() throws {
        let json = Data(#"{"rateLimits":{"primary":{"usedPercent":-8,"windowDurationMins":300},"secondary":{"usedPercent":125,"windowDurationMins":10080}}}"#.utf8)
        let snapshot = try CodexClient.snapshot(from: json, accountPlan: "plus", fetchedAt: .distantPast)
        #expect(snapshot.planName == "Plus")
        #expect(snapshot.windows.map(\.title) == ["Session", "Weekly"])
        #expect(snapshot.windows.map(\.remainingPercent) == [100, 0])
        #expect(snapshot.windows.allSatisfy { $0.resetsAt == nil })
    }

    @Test func unavailableLimitsAreNeverDisplayedAsFullAllowance() {
        let json = Data(#"{"rateLimits":{"primary":null,"secondary":null}}"#.utf8)
        #expect(throws: CodexClientError.noUsageAvailable) {
            try CodexClient.snapshot(from: json, accountPlan: "pro", fetchedAt: .now)
        }
    }

    @Test func unrelatedModelBucketCannotReplaceCodexAllowance() {
        let json = Data(#"{"rateLimits":{"limitId":"other_model","primary":{"usedPercent":1}}}"#.utf8)
        #expect(throws: CodexClientError.noUsageAvailable) {
            try CodexClient.snapshot(from: json, accountPlan: "pro", fetchedAt: .now)
        }
    }
}

/// A real newline-JSON subprocess exercises transport, without touching Codex authentication.
private struct FixtureServer {
    let directory: URL
    let executable: URL

    init(mode: String, usesEnvInterpreter: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("quota bar test \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptFile = directory.appendingPathComponent("codex-fixture")
        var script = Self.script
        if usesEnvInterpreter {
            let bin = directory.appendingPathComponent("chosen bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let interpreter = bin.appendingPathComponent("quota-bar-fixture-python")
            // /usr/bin/python3 is an xcode-select shim on some Macs and cannot be
            // invoked through a differently named symlink. Give env a local wrapper.
            try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: interpreter, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: interpreter.path)
            executable = bin.appendingPathComponent("codex")
            try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: scriptFile)
            script = script.replacingOccurrences(of: "#!/usr/bin/python3", with: "#!/usr/bin/env quota-bar-fixture-python")
        } else {
            executable = scriptFile
        }
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptFile.path)
        try setMode(mode)
    }

    func setMode(_ mode: String) throws {
        try mode.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    func methods() throws -> [String] {
        let url = directory.appendingPathComponent("methods")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func waitForMethod(_ method: String) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if try methods().contains(method) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CodexClientError.timedOut
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let script = #"""
    #!/usr/bin/python3
    import json, os, pathlib, sys, time
    root = pathlib.Path(__file__).resolve().parent
    initialized = False
    def respond(request, result=None, error=None):
        response = {"id": request["id"]}
        response["error" if error else "result"] = error or result
        text = json.dumps(response) + "\n"
        sys.stdout.write(text[:11]); sys.stdout.flush()
        time.sleep(0.002)
        sys.stdout.write(text[11:]); sys.stdout.flush()
    for line in sys.stdin:
        request = json.loads(line)
        method = request["method"]
        with (root / "methods").open("a") as log: log.write(method + "\n")
        mode = (root / "mode").read_text()
        if mode == "minimalEnvironment":
            assert os.environ["HOME"] == "/test-only/home with spaces"
            assert os.environ["CODEX_HOME"] == "/test-only/custom codex home"
            assert os.environ["OPENAI_API_KEY"] == "fixture-only-value"
        if method == "initialize":
            assert request["params"]["clientInfo"]["name"] == "macaiusage"
            if mode == "slowInitialize": time.sleep(0.25)
            respond(request, {"userAgent":"fixture"})
        elif method == "initialized":
            initialized = True
        elif method == "account/read":
            assert initialized
            assert request["params"]["refreshToken"] is False
            if mode == "timeout": continue
            if mode == "exit": sys.exit(7)
            if mode == "malformed":
                sys.stdout.write("not-json\n"); sys.stdout.flush(); continue
            if mode == "oversized":
                sys.stdout.write("x" * 1200000); sys.stdout.flush(); continue
            if mode == "remoteError":
                respond(request, error={"code":-32001,"message":"private details must not be displayed"}); continue
            account = None if mode == "signedOut" else {"type":"apiKey"} if mode == "apiKey" else {"type":"chatgpt", "planType":"pro", "email":"not-retained@example.invalid"}
            respond(request, {"account":account,"requiresOpenaiAuth":True})
        elif method == "account/rateLimits/read":
            sys.stdout.write('{"method":"account/rateLimits/updated","params":{}}\n'); sys.stdout.flush()
            main = {"primary":{"usedPercent":49,"windowDurationMins":10080,"resetsAt":1789440455},"secondary":None,"planType":"pro"}
            other = {"primary":{"usedPercent":99,"windowDurationMins":300}}
            respond(request, {"rateLimits":other,"rateLimitsByLimitId":{"codex":main,"other":other}})
        elif method == "account/login/start":
            assert request["params"] == {"type":"chatgpt"}
            respond(request, {"type":"chatgpt","authUrl":"https://auth.openai.com/test-only","loginId":"fixture"})
        else:
            raise RuntimeError("Unexpected mutating or unsupported request: " + method)
    """#
}
