import Foundation
import Darwin

/// Detects changes to Codex's persisted sign-in and credential-store configuration.
/// Only filesystem metadata is inspected; credentials and configuration are never read.
public struct CodexAuthMonitor: Sendable {
    public let codexHome: URL
    private var previous: [FileState?]

    public init(codexHome: URL? = nil) {
        let home = codexHome ?? Self.resolveHome(
            environment: ProcessInfo.processInfo.environment,
            userHome: FileManager.default.homeDirectoryForCurrentUser
        )
        self.codexHome = home
        self.previous = Self.snapshot(at: home)
    }

    /// Returns true once for each observed change, including creation, deletion,
    /// in-place updates, and atomic replacement of either file.
    public mutating func consumeChange() -> Bool {
        let current = Self.snapshot(at: codexHome)
        guard current != previous else { return false }
        previous = current
        return true
    }

    static func resolveHome(environment: [String: String], userHome: URL) -> URL {
        if let path = environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        }
        return userHome.appendingPathComponent(".codex", isDirectory: true)
    }

    private static func snapshot(at home: URL) -> [FileState?] {
        ["auth.json", "config.toml"].map { name in
            var attributes = stat()
            guard stat(home.appendingPathComponent(name).path, &attributes) == 0 else { return nil }
            return FileState(
                device: attributes.st_dev,
                inode: attributes.st_ino,
                size: attributes.st_size,
                modifiedSeconds: attributes.st_mtimespec.tv_sec,
                modifiedNanoseconds: attributes.st_mtimespec.tv_nsec,
                changedSeconds: attributes.st_ctimespec.tv_sec,
                changedNanoseconds: attributes.st_ctimespec.tv_nsec
            )
        }
    }

    private struct FileState: Sendable, Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }
}
