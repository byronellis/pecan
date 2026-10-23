import Foundation

/// Single-instance lock for the server, held via flock(2) for the life of the process.
///
/// The kernel releases it if the server crashes, so a held lock always means a live server
/// (possibly still starting up) and a socket file without one is stale.
public final class ServerLock: Sendable {
    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Takes the lock, or returns nil if another process holds it.
    public static func acquire(at path: String) throws -> ServerLock? {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError.current }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = POSIXError.current
            close(fd)
            if error.code == .EWOULDBLOCK { return nil }
            throw error
        }
        // Record the owner for diagnostics; the lock itself is what matters.
        let pid = "\(getpid())\n"
        ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return ServerLock(fd: fd)
    }

    /// Whether a server currently holds the lock at `path`.
    public static func isHeld(at path: String) -> Bool {
        do {
            guard let probe = try acquire(at: path) else { return true }
            probe.release()
            return false
        } catch {
            return false
        }
    }

    public func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

extension POSIXError {
    static var current: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
