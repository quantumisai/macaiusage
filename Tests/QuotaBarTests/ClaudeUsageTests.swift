import Foundation
import Testing
@testable import UsageCore
@testable import QuotaBar

// Bound concurrent Python fixture processes so transport deadlines test the client, not interpreter startup contention.
@Suite(.serialized)
@MainActor
struct ClaudeUsageTests {
    @Test func readsSubscriptionAndScopedWindowsWithoutModelCalls() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.remove() }
        let client = fixture.client()
        let snapshot = try await client.fetchUsage()
        #expect(snapshot.planName == "Max")
        #expect(snapshot.windows.map(\.remainingPercent) == [84, 66, 90])
        #expect(snapshot.windows.map(\.title) == ["Session", "Weekly", "Weekly · Fable"])
        #expect(snapshot.windows[0].resetsAt == nil)
        #expect(snapshot.windows[1].resetsAt != nil)
        #expect(try fixture.requests() == ["initialize", "get_usage"])
        #expect(TrackedWindow.weekly.select(from: snapshot)?.remainingPercent == 66)
    }

    @Test func refreshStartsFreshAndUsesChangedAccount() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.remove() }
        let client = fixture.client()
        #expect(try await client.fetchUsage().planName == "Max")
        try fixture.setMode("second")
        let changed = try await client.fetchUsage()
        #expect(changed.planName == "Pro")
        #expect(changed.windows.first?.remainingPercent == 40)
        #expect(try fixture.requests().filter { $0 == "initialize" }.count == 2)
    }

    @Test(arguments: ["signedOut", "apiKey", "empty"])
    func unavailableNeverBecomesZeroUsage(mode: String) async throws {
        let fixture = try ClaudeFixture(mode: mode)
        defer { fixture.remove() }
        await #expect(throws: ClaudeClientError.unavailable) { try await fixture.client().fetchUsage() }
    }

    @Test(arguments: ["error", "malformed", "oversized", "badDate", "outOfRange"])
    func rejectsUnsupportedOrInvalidData(mode: String) async throws {
        let fixture = try ClaudeFixture(mode: mode)
        defer { fixture.remove() }
        await #expect(throws: ClaudeClientError.invalidResponse) { try await fixture.client().fetchUsage() }
    }

    @Test func timeoutAndCancellationAllowNextRefresh() async throws {
        let fixture = try ClaudeFixture(mode: "timeout")
        defer { fixture.remove() }
        let client = fixture.client(timeout: .seconds(2))
        await #expect(throws: ClaudeClientError.timedOut) { try await client.fetchUsage() }
        let previousRequests = (try? fixture.requests().filter { $0 == "get_usage" }.count) ?? 0
        let pending = Task { try await client.fetchUsage() }
        try await waitUntil { (try? fixture.requests().filter { $0 == "get_usage" }.count) == previousRequests + 1 }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        try fixture.setMode("success")
        #expect(try await client.fetchUsage().planName == "Max")
    }

    @Test func claudeFailureDoesNotEraseCodexAndRecoveryWorks() async throws {
        let fixture = try ClaudeFixture(mode: "signedOut")
        defer { fixture.remove() }
        let model = AppModel(claudeClient: fixture.client(), anthropicEnabled: true)
        defer { model.stop() }
        let codex = UsageSnapshot(planName: "Pro", windows: [], fetchedAt: Date(), accountEmail: "fixture@example.invalid")
        model.snapshot = codex
        model.refreshAnthropic()
        try await waitUntil { !model.isAnthropicRefreshing }
        #expect(model.snapshot == codex)
        #expect(model.anthropicSnapshot == nil)
        #expect(model.anthropicError != nil)
        try fixture.setMode("success")
        model.refreshAnthropic()
        try await waitUntil { !model.isAnthropicRefreshing }
        #expect(model.snapshot == codex)
        #expect(model.anthropicSnapshot?.planName == "Max")
        #expect(model.anthropicError == nil)
        try fixture.setMode("signedOut")
        model.refreshAnthropic()
        try await waitUntil { !model.isAnthropicRefreshing }
        #expect(model.anthropicSnapshot == nil)
        #expect(model.snapshot == codex)
    }

    @Test func tooltipIdentifiesAnthropicAndMissingData() {
        let preferences = UsagePreferences()
        let snapshot = UsageSnapshot(planName: "Max", windows: [], fetchedAt: Date())
        let tooltip = UsageFormatting.tooltip(snapshot: snapshot, preferences: preferences, now: Date(), isStale: false, provider: "Anthropic / Claude")
        #expect(tooltip.contains("Anthropic / Claude"))
        #expect(!tooltip.contains("Codex"))
        #expect(UsageFormatting.tooltip(snapshot: nil, preferences: preferences, now: Date(), isStale: false, provider: "Anthropic").contains("unavailable"))
    }

    @Test func executableDiscoveryOrdersConductorVersionsNumerically() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let base = home.appendingPathComponent("Library/Application Support/com.conductor.app/agent-binaries/claude")
        for version in ["2.1.99", "2.1.280"] {
            let directory = base.appendingPathComponent(version)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("claude")
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        #expect(ClaudeClient.locateExecutable(home: home)?.path.contains("2.1.280") == true)
        #expect(ClaudeClient.locateExecutable(override: "/nonexistent/test/claude", home: home) == nil)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }
}

@MainActor
private struct ClaudeFixture {
    let directory: URL
    var executable: URL { directory.appendingPathComponent("claude") }
    init(mode: String = "success") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-claude-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try setMode(mode)
    }
    func client(timeout: Duration = .seconds(6)) -> ClaudeClient { ClaudeClient(executablePath: executable.path, timeout: timeout) }
    func setMode(_ mode: String) throws { try mode.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8) }
    func requests() throws -> [String] { try String(contentsOf: directory.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n").map(String.init) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    private static let script = #"""
    #!/usr/bin/python3
    import json, pathlib, sys, time
    root = pathlib.Path(__file__).resolve().parent
    mode = (root / "mode").read_text()
    assert "--safe-mode" in sys.argv and "--no-session-persistence" in sys.argv
    assert sys.argv[sys.argv.index("--tools") + 1] == ""
    for line in sys.stdin:
        request = json.loads(line)
        assert request["type"] == "control_request"
        subtype = request["request"]["subtype"]
        with (root / "requests").open("a") as log: log.write(subtype + "\n")
        assert subtype in ("initialize", "get_usage")
        body = {}
        if subtype == "get_usage":
            assert request["request"]["skip_behaviors"] is True
            if mode == "timeout": continue
            if mode == "malformed":
                sys.stdout.write("invalid\n"); sys.stdout.flush(); continue
            if mode == "oversized":
                sys.stdout.write("x" * 1200000); sys.stdout.flush(); continue
            body = {"subscription_type": "pro" if mode == "second" else "max", "rate_limits_available": mode not in ("signedOut", "apiKey"), "rate_limits": {
                "five_hour": {"utilization": 60 if mode == "second" else 16, "resets_at": None},
                "seven_day": {"utilization": 34, "resets_at": "2026-09-25T17:59:59.865267+00:00"},
                "model_scoped": [{"display_name":"Fable", "utilization":10, "resets_at":"2026-09-25T18:00:00Z"}]
            }}
            if mode == "empty": body["rate_limits"] = {}
            if mode == "badDate": body["rate_limits"]["seven_day"]["resets_at"] = "not a date"
            if mode == "outOfRange": body["rate_limits"]["five_hour"]["utilization"] = 900
        response = {"type":"control_response", "response":{"request_id":request["request_id"], "subtype":"error" if mode == "error" else "success", "response":body}}
        text = json.dumps(response) + "\n"
        sys.stdout.write(text[:8]); sys.stdout.flush(); time.sleep(.002)
        sys.stdout.write(text[8:]); sys.stdout.flush()
    """#
}
