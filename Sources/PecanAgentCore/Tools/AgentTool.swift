import Foundation

// MARK: - RunAgentTool

public struct RunAgentTool: PecanTool, Sendable {
    public let name = "run_agent"
    public let description = """
        Spawn a subagent to perform a bounded task in its own context window. \
        The subagent runs independently, executes tools as needed, and returns \
        a summary when complete. Use this to delegate research, analysis, or \
        implementation subtasks without bloating the main context.
        """
    public let tags: Set<String> = ["meta"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "task": {
                "type": "string",
                "description": "Complete description of the task for the subagent. Be specific — the subagent starts with a fresh context."
            },
            "persona": {
                "type": "string",
                "description": "Optional persona for the subagent (e.g. 'planning'). Defaults to the coding role."
            },
            "tool_tags": {
                "type": "array",
                "items": { "type": "string" },
                "description": "Tool categories to give the subagent. Defaults to ['core', 'web', 'skills']."
            }
        },
        "required": ["task"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let task = args["task"] as? String, !task.isEmpty else {
            throw ToolError.invalidArguments("Missing required parameter: task")
        }

        let personaName = args["persona"] as? String
        let toolTags: Set<String>?
        if let tags = args["tool_tags"] as? [String] {
            toolTags = Set(tags)
        } else {
            toolTags = nil
        }

        let result = try await SubagentPool.shared.spawn(
            task: task,
            personaName: personaName,
            toolTags: toolTags
        )
        return result
    }
}
