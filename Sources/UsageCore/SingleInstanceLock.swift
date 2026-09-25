import Darwin
import Foundation

/// A process-held lock shared by every installed copy for this user.
/// Keep the file in place: unlinking it could let two processes lock different inodes.
public final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(at url: URL) throws -> SingleInstanceLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return SingleInstanceLock(descriptor: descriptor)
    }

    deinit { close(descriptor) }
}
