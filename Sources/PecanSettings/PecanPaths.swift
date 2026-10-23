import Foundation

/// Per-channel runtime locations.
///
/// Dev and release builds use separate homes (`~/.pecan-dev` and `~/.pecan`) so a development
/// server never replaces, or shares a database with, the installed one. `PECAN_HOME` overrides both.
public enum PecanPaths {
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["PECAN_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let name = BuildInfo.current.channel == .release ? ".pecan" : ".pecan-dev"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
    }

    public static var runDirectory: URL { home.appendingPathComponent("run") }

    public static var socketPath: String { runDirectory.appendingPathComponent("pecan.sock").path }
    public static var lockPath: String { runDirectory.appendingPathComponent("server.lock").path }
    public static var logPath: String { runDirectory.appendingPathComponent("server.log").path }

    public static func ensureRunDirectory() throws {
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
