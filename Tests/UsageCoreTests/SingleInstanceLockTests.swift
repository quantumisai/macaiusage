import Foundation
import Testing
@testable import UsageCore

struct SingleInstanceLockTests {
    @Test func secondOwnerIsRejectedAndExitReleasesLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        var first = try SingleInstanceLock.acquire(at: url)
        #expect(first != nil)
        #expect(try SingleInstanceLock.acquire(at: url) == nil)
        first = nil
        let replacement = try SingleInstanceLock.acquire(at: url)
        #expect(replacement != nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        withExtendedLifetime(replacement) {}
    }

    @Test func separateUsersOrTestDirectoriesDoNotConflict() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SingleInstanceLock.acquire(at: directory.appendingPathComponent("one/instance.lock"))
        let second = try SingleInstanceLock.acquire(at: directory.appendingPathComponent("two/instance.lock"))
        #expect(first != nil)
        #expect(second != nil)
        withExtendedLifetime((first, second)) {}
    }

    @Test func fileErrorsAreNotMistakenForAnExistingInstance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try SingleInstanceLock.acquire(at: directory)
            Issue.record("Opening a directory as a lock file must throw")
        } catch {
            #expect(error is POSIXError)
        }
    }
}
