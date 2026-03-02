import Foundation

enum LauncherRequest: Codable {
    case spawn(SpawnRequest)
    case terminate(TerminateRequest)

    struct SpawnRequest: Codable {
        let type: String // "spawn"
        let sessionID: String
        let grpcSocketPath: String
    }

    struct TerminateRequest: Codable {
        let type: String // "terminate"
        let sessionID: String
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "spawn":
            self = .spawn(try SpawnRequest(from: decoder))
        case "terminate":
            self = .terminate(try TerminateRequest(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown request type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .spawn(let req):
            try req.encode(to: encoder)
        case .terminate(let req):
            try req.encode(to: encoder)
        }
    }
}

struct LauncherResponse: Codable {
    let type: String // "spawn_ok", "spawn_error", "terminate_ok", "terminate_error"
    let sessionID: String
    let error: String?

    init(type: String, sessionID: String, error: String? = nil) {
        self.type = type
        self.sessionID = sessionID
        self.error = error
    }

    static func spawnOK(sessionID: String) -> LauncherResponse {
        LauncherResponse(type: "spawn_ok", sessionID: sessionID)
    }

    static func spawnError(sessionID: String, error: String) -> LauncherResponse {
        LauncherResponse(type: "spawn_error", sessionID: sessionID, error: error)
    }

    static func terminateOK(sessionID: String) -> LauncherResponse {
        LauncherResponse(type: "terminate_ok", sessionID: sessionID)
    }

    static func terminateError(sessionID: String, error: String) -> LauncherResponse {
        LauncherResponse(type: "terminate_error", sessionID: sessionID, error: error)
    }
}
