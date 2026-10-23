import Foundation
import PecanSettings

enum ServerProcess {
    struct SpawnError: Error, CustomStringConvertible {
        var description: String
    }

    /// Starts `<this executable> server run` in a new session, detached from the terminal so it
    /// outlives the client and ignores its Ctrl-C, with output appended to the server log.
    static func spawn() throws {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            throw SpawnError(description: "cannot determine the path of the pecan executable")
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(
            &actions, STDOUT_FILENO, PecanPaths.logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

        let arguments = [executable, "server", "run"].map { strdup($0) }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (arguments + environment).forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, arguments + [nil], environment + [nil])
        guard result == 0 else {
            throw SpawnError(description: "failed to start pecan server: \(String(cString: strerror(result)))")
        }

        // The server is still our child; reap it whenever it exits so it never lingers as a zombie.
        let child = pid
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }
    }
}
