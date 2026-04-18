import Foundation

// MARK: - TriggerCreateTool

public struct TriggerCreateTool: PecanTool, Sendable {
    public let name = "trigger_create"
    public let description = "Schedule a future instruction to yourself. One-shot by default; set interval_seconds for repeating."
    public let tags: Set<String> = ["invoke_only"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "instruction": { "type": "string", "description": "The instruction to deliver when the trigger fires." },
            "fire_at": { "type": "string", "description": "ISO 8601 datetime for when to fire the trigger." },
            "interval_seconds": { "type": "integer", "description": "If set, trigger repeats at this interval after firing. 0 means one-shot." }
        },
        "required": ["instruction", "fire_at"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        var payload: [String: Any] = [
            "instruction": args["instruction"] as? String ?? "",
            "fire_at": args["fire_at"] as? String ?? ""
        ]
        if let interval = args["interval_seconds"] as? Int { payload["interval_seconds"] = interval }
        return try await TaskClient.shared.sendCommand(action: "trigger_create", payload: payload)
    }

    public func formatResult(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let id = obj["id"] ?? "?"
        let fireAt = obj["fire_at"] as? String ?? ""
        let interval = obj["interval_seconds"] as? Int ?? 0
        let repeatStr = interval > 0 ? " (repeats every \(interval)s)" : " (one-shot)"
        return "Trigger #\(id) scheduled for \(fireAt)\(repeatStr)"
    }
}

// MARK: - TriggerListTool

public struct TriggerListTool: PecanTool, Sendable {
    public let name = "trigger_list"
    public let description = "List scheduled triggers. Defaults to active triggers."
    public let tags: Set<String> = ["invoke_only"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "status": { "type": "string", "description": "Filter by status: active, fired, cancelled. Default: active." }
        }
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = (try? parseArguments(argumentsJSON)) ?? [:]
        var payload: [String: Any] = [:]
        if let status = args["status"] as? String { payload["status"] = status }
        else { payload["status"] = "active" }
        return try await TaskClient.shared.sendCommand(action: "trigger_list", payload: payload)
    }

    public func formatResult(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        if arr.isEmpty { return "(no triggers)" }
        var lines: [String] = []
        for t in arr {
            let id = t["id"] ?? "?"
            let instruction = t["instruction"] as? String ?? ""
            let fireAt = t["fire_at"] as? String ?? ""
            let interval = t["interval_seconds"] as? Int ?? 0
            let preview = instruction.count > 60 ? String(instruction.prefix(60)) + "..." : instruction
            let repeatStr = interval > 0 ? " (every \(interval)s)" : ""
            lines.append("#\(id) \(fireAt)\(repeatStr): \(preview)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - TriggerCancelTool

public struct TriggerCancelTool: PecanTool, Sendable {
    public let name = "trigger_cancel"
    public let description = "Cancel an active trigger."
    public let tags: Set<String> = ["invoke_only"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "trigger_id": { "type": "integer", "description": "The trigger ID to cancel." }
        },
        "required": ["trigger_id"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        let triggerID = args["trigger_id"] as? Int ?? 0
        return try await TaskClient.shared.sendCommand(action: "trigger_cancel", payload: ["trigger_id": triggerID])
    }

    public func formatResult(_ result: String) -> String? { "Trigger cancelled." }
}
