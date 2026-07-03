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

    public static var statusFilePath: String {
        "\(FileManager.default.currentDirectoryPath)/.run/server.json"
    }

    // MARK: - Persistence

    public func write() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: Self.statusFilePath), options: .atomic)
    }

    public static func read() throws -> ServerStatus {
        let data = try Data(contentsOf: URL(fileURLWithPath: statusFilePath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ServerStatus.self, from: data)
    }

    public static func remove() {
        try? FileManager.default.removeItem(atPath: statusFilePath)
    }

    /// Returns true if the PID in the status file belongs to a running process.
    public var isAlive: Bool {
        kill(pid, 0) == 0
    }
}
