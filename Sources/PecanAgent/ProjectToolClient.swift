import Foundation
import PecanShared

/// Forwards project tool execution requests to the server via gRPC.
/// Follows the same continuation pattern as TaskClient and MemoryClient.
public actor ProjectToolClient {
    public static let shared = ProjectToolClient()

    private var pendingRequests: [String: CheckedContinuation<String, Error>] = [:]
    private var sendCallback: (@Sendable (Pecan_AgentEvent) async throws -> Void)?

    public func configure(send: @escaping @Sendable (Pecan_AgentEvent) async throws -> Void) {
        self.sendCallback = send
    }

    public func handleResponse(_ response: Pecan_ToolExecutionResponse) {
        guard let continuation = pendingRequests.removeValue(forKey: response.requestID) else { return }
        if !response.errorMessage.isEmpty {
            continuation.resume(throwing: NSError(
                domain: "ProjectToolClient", code: 1,
                userInfo: [NSLocalizedDescriptionKey: response.errorMessage]
            ))
        } else {
            continuation.resume(returning: response.resultJson)
        }
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        guard let send = sendCallback else {
            throw NSError(
                domain: "ProjectToolClient", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "ProjectToolClient not configured"]
            )
        }
        let requestID = UUID().uuidString

        var msg = Pecan_AgentEvent()
        var req = Pecan_ToolExecutionRequest()
        req.requestID = requestID
        req.toolName = toolName
        req.argumentsJson = argumentsJSON
        msg.toolRequest = req

        try await send(msg)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
        }
    }
}

// MARK: - ProjectTool

/// A PecanTool implementation that executes via the server-side ProjectToolRegistry.
public struct ProjectTool: PecanTool, Sendable {
    public let name: String
    public let description: String
    public let parametersJSONSchema: String
    public var tags: Set<String> { ["project"] }

    public init(definition: Pecan_ProjectToolDefinition) {
        self.name = definition.name
        self.description = definition.description_p
        self.parametersJSONSchema = definition.parametersJsonSchema.isEmpty
            ? #"{"type":"object","properties":{}}"#
            : definition.parametersJsonSchema
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let raw = try await ProjectToolClient.shared.execute(toolName: name, argumentsJSON: argumentsJSON)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return raw }

        let output = obj["output"] as? String ?? ""
        let exitCode = obj["exit_code"] as? Int ?? -1
        let success = obj["success"] as? Bool ?? false
        let header = success ? "exit 0" : "exit \(exitCode)"

        if let filePath = obj["output_file"] as? String {
            return "[\(header) — full output at \(filePath)]\n\(output)"
        }
        return "[\(header)]\n\(output)"
    }
}
