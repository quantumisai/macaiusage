import Foundation
import Testing
@testable import UsageCore

struct CodexAuthMonitorTests {
    @Test(arguments: ["auth.json", "config.toml"])
    func detectsCreationUpdatesAndDeletion(filename: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var monitor = CodexAuthMonitor(codexHome: directory)
        let file = directory.appendingPathComponent(filename)
        let initiallyChanged = monitor.consumeChange()
        #expect(!initiallyChanged)

        try Data("fixture only".utf8).write(to: file)
        let created = monitor.consumeChange()
        #expect(created)
        let creationConsumed = monitor.consumeChange()
        #expect(!creationConsumed)

        try Data("updated fixture only".utf8).write(to: file)
        let updated = monitor.consumeChange()
        #expect(updated)
        let updateConsumed = monitor.consumeChange()
        #expect(!updateConsumed)

        try FileManager.default.removeItem(at: file)
        let deleted = monitor.consumeChange()
        #expect(deleted)
        let deletionConsumed = monitor.consumeChange()
        #expect(!deletionConsumed)
    }

    @Test func detectsAtomicReplacementEvenWithMatchingSizeAndModificationTime() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("first".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        var monitor = CodexAuthMonitor(codexHome: directory)

        try Data("other".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        let replaced = monitor.consumeChange()
        #expect(replaced)
        let replacementConsumed = monitor.consumeChange()
        #expect(!replacementConsumed)
    }

    @Test func usesExistingFilesAsBaselineAndIgnoresUnrelatedFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not valid JSON; contents need not be read".utf8)
            .write(to: directory.appendingPathComponent("auth.json"))
        var monitor = CodexAuthMonitor(codexHome: directory)
        let existingFileChanged = monitor.consumeChange()
        #expect(!existingFileChanged)
        try Data("unrelated".utf8).write(to: directory.appendingPathComponent("history.jsonl"))
        let unrelatedFileChanged = monitor.consumeChange()
        #expect(!unrelatedFileChanged)
    }

    @Test func honorsCodexHomeAndFallsBackToTheUserHome() {
        let userHome = URL(fileURLWithPath: "/test-only/user home", isDirectory: true)
        #expect(CodexAuthMonitor.resolveHome(environment: [:], userHome: userHome).path == "/test-only/user home/.codex")
        #expect(CodexAuthMonitor.resolveHome(environment: ["CODEX_HOME": ""], userHome: userHome).path == "/test-only/user home/.codex")
        #expect(CodexAuthMonitor.resolveHome(environment: ["CODEX_HOME": "/test-only/custom home"], userHome: userHome).path == "/test-only/custom home")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quota-bar-auth-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
