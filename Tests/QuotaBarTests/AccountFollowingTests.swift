import Foundation
import Testing
import UsageCore
@testable import QuotaBar

@MainActor
struct AccountFollowingTests {
    @Test func switchesImmediatelyAndClearsUsageOnSignOut() async throws {
        let server = try AccountFixture()
        defer { server.remove() }
        let model = server.makeModel()
        defer { model.stop() }
        model.refresh()
        try await waitUntil { !model.isRefreshing }
        #expect(model.snapshot?.accountEmail == "first@example.invalid")

        try server.hold()
        try server.setAccount("second")
        model.tick()
        #expect(model.snapshot == nil)
        #expect(model.isRefreshing)
        server.release()
        try await waitUntil { !model.isRefreshing }
        #expect(model.snapshot?.accountEmail == "second@example.invalid")
        #expect(model.snapshot?.windows.first?.remainingPercent == 80)

        try server.setAccount(nil)
        model.tick()
        #expect(model.snapshot == nil)
        try await waitUntil { !model.isRefreshing }
        #expect(model.snapshot == nil)
        #expect(model.errorMessage == CodexClientError.signInRequired.localizedDescription)
    }

    @Test(arguments: [false, true])
    func rejectsOldAccountResponseDuringSwitch(detectOnTick: Bool) async throws {
        let server = try AccountFixture()
        defer { server.remove() }
        let model = server.makeModel()
        defer { model.stop() }
        try server.hold()
        var publishedAccounts: [String] = []
        model.onChange = { [weak model] in
            if let email = model?.snapshot?.accountEmail { publishedAccounts.append(email) }
        }
        model.refresh()
        try await waitUntil { server.hasReadLimits }
        try server.setAccount("second")
        if detectOnTick { model.tick() }
        server.release()
        try await waitUntil { !model.isRefreshing }

        #expect(model.snapshot?.accountEmail == "second@example.invalid")
        #expect(model.snapshot?.windows.first?.remainingPercent == 80)
        #expect(!publishedAccounts.contains("first@example.invalid"))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "The account refresh did not complete")
    }
}

@MainActor
private struct AccountFixture {
    let directory: URL
    var executable: URL { directory.appendingPathComponent("codex") }
    var hasReadLimits: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("reading-limits").path) }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-account-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try setAccount("first")
    }

    func makeModel() -> AppModel {
        AppModel(client: CodexClient(executablePath: executable.path), authMonitor: CodexAuthMonitor(codexHome: directory), anthropicEnabled: false)
    }

    func setAccount(_ name: String?) throws {
        // Dummy fixture identities only; never use or change real Codex credentials.
        try (name ?? "signed-out").write(to: directory.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
    }

    func hold() throws { try Data().write(to: directory.appendingPathComponent("hold")) }
    func release() { try? FileManager.default.removeItem(at: directory.appendingPathComponent("hold")) }
    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static let script = #"""
    #!/usr/bin/python3
    import json, pathlib, sys, time
    root = pathlib.Path(__file__).resolve().parent
    account = (root / "auth.json").read_text()
    for line in sys.stdin:
        request = json.loads(line)
        method = request["method"]
        if method == "initialize":
            result = {"userAgent": "fixture"}
        elif method == "initialized":
            continue
        elif method == "account/read":
            identity = None if account == "signed-out" else {"type":"chatgpt", "planType":"pro", "email": account + "@example.invalid"}
            result = {"account": identity}
        elif method == "account/rateLimits/read":
            (root / "reading-limits").touch()
            while (root / "hold").exists(): time.sleep(0.01)
            result = {"rateLimits": {"primary": {"usedPercent": 60 if account == "first" else 20, "windowDurationMins": 10080}}}
        else:
            raise RuntimeError("Unexpected request: " + method)
        sys.stdout.write(json.dumps({"id": request["id"], "result": result}) + "\n")
        sys.stdout.flush()
    """#
}
