import Foundation

/// Written to .run/server.json when the server starts; deleted on clean shutdown.
/// Clients (UI, scripts) read this to discover the server's port and PID.
public struct ServerStatus: Codable {
    public let pid: Int32
    public let port: Int
    public let grpcSocketPath: String
    public let startedAt: Date

    public init(pid: Int32, port: Int, grpcSocketPath: String, startedAt: Date = Date()) {
        self.pid = pid
        self.port = port
        self.grpcSocketPath = grpcSocketPath
        self.startedAt = startedAt
    }

    // MARK: - File location

    /// Returns the status file path for the given working directory (defaults to CWD).
    public static func statusFilePath(in directory: String? = nil) -> String {
        let base = directory ?? FileManager.default.currentDirectoryPath
        return "\(base)/.run/server.json"
    }

    // MARK: - Persistence

    public func write(to directory: String? = nil) throws {
        let path = Self.statusFilePath(in: directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func read(from directory: String? = nil) throws -> ServerStatus {
        let path = statusFilePath(in: directory)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ServerStatus.self, from: data)
    }

    public static func remove(from directory: String? = nil) {
        let path = statusFilePath(in: directory)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Returns true if the PID in the status file belongs to a running process.
    public var isAlive: Bool {
        kill(pid, 0) == 0
    }
}
