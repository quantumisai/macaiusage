import Foundation
import Testing
@testable import UsageCore

@MainActor
struct CodexLoginTests {
    @Test func existingAccountDoesNotCompletePendingBrowserSignIn() async throws {
        let fixture = try LoginFixture(mode: "pending")
        defer { fixture.remove() }
        let client = CodexClient(executablePath: fixture.executable.path)
        defer { client.stop() }

        #expect(try await client.fetchUsage().accountEmail == "first@example.invalid")
        _ = try await client.startSignIn()
        #expect(try !client.isSignInComplete())
        #expect(try await client.fetchUsage().accountEmail == "first@example.invalid")
        #expect(try !client.isSignInComplete())
    }

    @Test func ignoresCompletionForAnotherLogin() async throws {
        let fixture = try LoginFixture(mode: "unrelated")
        defer { fixture.remove() }
        let client = CodexClient(executablePath: fixture.executable.path)
        defer { client.stop() }

        _ = try await client.startSignIn()
        _ = try await client.fetchUsage()
        #expect(try !client.isSignInComplete())
    }

    @Test(arguments: ["success", "combinedSuccess"])
    func acceptsMatchingSuccessAndResetsOnStop(mode: String) async throws {
        let fixture = try LoginFixture(mode: mode)
        defer { fixture.remove() }
        let client = CodexClient(executablePath: fixture.executable.path)
        defer { client.stop() }

        _ = try await client.startSignIn()
        if mode == "success" { #expect(try !client.isSignInComplete()) }
        _ = try await client.fetchUsage()
        #expect(try client.isSignInComplete())
        client.stop()
        #expect(try !client.isSignInComplete())
    }

    @Test(arguments: ["failure", "combinedFailure"])
    func reportsMatchingFailureWithoutItsPrivateErrorText(mode: String) async throws {
        let fixture = try LoginFixture(mode: mode)
        defer { fixture.remove() }
        let client = CodexClient(executablePath: fixture.executable.path)
        defer { client.stop() }

        _ = try await client.startSignIn()
        _ = try await client.fetchUsage()
        #expect(throws: CodexClientError.signInFailed) { try client.isSignInComplete() }
        #expect(!CodexClientError.signInFailed.localizedDescription.contains("fixture-sensitive-error"))
    }

    @Test func startingAnotherLoginClearsPreviousCompletion() async throws {
        let fixture = try LoginFixture(mode: "reset")
        defer { fixture.remove() }
        let client = CodexClient(executablePath: fixture.executable.path)
        defer { client.stop() }

        _ = try await client.startSignIn()
        _ = try await client.fetchUsage()
        #expect(try client.isSignInComplete())
        _ = try await client.startSignIn()
        _ = try await client.fetchUsage()
        #expect(try !client.isSignInComplete())
    }
}

private struct LoginFixture {
    let directory: URL
    var executable: URL { directory.appendingPathComponent("codex") }

    init(mode: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-login-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try mode.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static let script = #"""
    #!/usr/bin/python3
    import json, pathlib, sys
    mode = (pathlib.Path(__file__).resolve().parent / "mode").read_text()
    login_count = 0
    notified = False
    def notification(login_id, success):
        return {"method": "account/login/completed", "params": {
            "loginId": login_id, "success": success, "error": None if success else "fixture-sensitive-error"
        }}
    for line in sys.stdin:
        request = json.loads(line)
        method = request["method"]
        messages = []
        if method == "initialize":
            result = {"userAgent": "fixture"}
        elif method == "initialized":
            continue
        elif method == "account/login/start":
            login_count += 1
            notified = False
            result = {"type": "chatgpt", "authUrl": "https://auth.openai.com/test-only", "loginId": str(login_count)}
            if mode in ("combinedSuccess", "combinedFailure"):
                messages.append({"id": request["id"], "result": result})
                messages.append(notification(str(login_count), mode == "combinedSuccess"))
                sys.stdout.write("".join(json.dumps(message) + "\n" for message in messages))
                sys.stdout.flush()
                notified = True
                continue
        elif method == "account/read":
            result = {"account": {"type": "chatgpt", "planType": "pro", "email": "first@example.invalid"}}
            if login_count and not notified:
                if mode in ("success", "failure"):
                    messages.append(notification(str(login_count), mode == "success"))
                elif mode == "unrelated":
                    messages.append(notification("another-login", True))
                elif mode == "reset":
                    messages.append(notification("1", True))
                notified = True
        elif method == "account/rateLimits/read":
            result = {"rateLimits": {"primary": {"usedPercent": 20, "windowDurationMins": 10080}}}
        else:
            raise RuntimeError("Unexpected request: " + method)
        messages.append({"id": request["id"], "result": result})
        sys.stdout.write("".join(json.dumps(message) + "\n" for message in messages))
        sys.stdout.flush()
    """#
}
